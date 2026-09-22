import Foundation

/// A decoded document and the bytes from which its last saved snapshot was made.
public struct TextFile: Sendable {
    public var text: String
    public var encoding: String.Encoding
    public var hasBOM: Bool
    /// Preferred ending for newly inserted lines. Existing endings are never normalized.
    /// The most frequent ending wins, with the first encountered ending breaking ties.
    /// Documents without line breaks use LF.
    public var lineEnding: String
    public var originalData: Data

    /// An exact content fingerprint, deliberately using full bytes rather than a lossy hash.
    /// Pass this as `expected` when saving against a snapshot.
    public var fingerprint: Data { originalData }

    public var hasMixedLineEndings: Bool {
        DocumentStorage.newlineStyle(in: text).mixed
    }

    // Provenance makes ordinary saves conflict checked without applying that snapshot to Save As.
    fileprivate var sourceURL: URL?

    public init(
        text: String,
        encoding: String.Encoding = .utf8,
        hasBOM: Bool = false,
        lineEnding: String? = nil,
        originalData: Data = Data()
    ) {
        self.text = text
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding ?? DocumentStorage.newlineStyle(in: text).preferred
        self.originalData = originalData
    }
}

public enum DocumentStorageError: Error, LocalizedError, Equatable, Sendable {
    case notFileURL(URL)
    case notRegularFile(URL)
    case fileTooLarge(limit: Int)
    case invalidEncoding
    case binaryFile
    case unsupportedEncoding(String.Encoding)
    case unrepresentableText(String.Encoding)
    case unsupportedBOM(String.Encoding)
    case externalChange(URL)
    /// The content was saved, but restoring its original POSIX permissions failed.
    case permissionsNotPreserved(URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notFileURL:
            return "Document storage requires a local file URL."
        case .notRegularFile:
            return "The selected item is not a regular file."
        case .fileTooLarge(let limit):
            return "The document exceeds the \(limit / 1_024 / 1_024) MB storage limit."
        case .invalidEncoding:
            return "The file is not valid Unicode text. Choose an explicit legacy encoding if appropriate."
        case .binaryFile:
            return "The file contains binary control characters and cannot be opened as text."
        case .unsupportedEncoding:
            return "The selected text encoding is not supported."
        case .unrepresentableText:
            return "The text cannot be saved in the selected encoding without losing characters."
        case .unsupportedBOM:
            return "The selected encoding does not support a byte order mark."
        case .externalChange:
            return "The file changed or was removed on disk. Reload it before saving."
        case .permissionsNotPreserved(_, let reason):
            return "The content was saved, but its original permissions could not be restored: \(reason)"
        }
    }
}

/// Byte-preserving storage for regular text files. No AppKit or editor dependency is required.
public enum DocumentStorage {
    public static let maximumFileSize = 256 * 1_024 * 1_024

    /// Reads BOM-marked UTF-8/16/32 or strict UTF-8. UTF-32 marks are checked before UTF-16.
    /// A fallback is used only when BOM-less data is not valid UTF-8; legacy encodings are
    /// never guessed.
    public static func read(_ url: URL, fallbackEncoding: String.Encoding? = nil) throws -> TextFile {
        let target = try resolvedFileURL(url)
        let data = try readBytes(at: target)
        var file = try decode(data, fallbackEncoding: fallbackEncoding)
        file.sourceURL = target
        return file
    }

    /// Restores a snapshot from original bytes, including its encoding, BOM and line endings.
    /// Recovery data has no source URL: pass the result's `fingerprint` as `expected` when
    /// saving recovered edits to protect against changes made since that snapshot.
    public static func decode(_ data: Data, fallbackEncoding: String.Encoding? = nil) throws -> TextFile {
        guard data.count <= maximumFileSize else {
            throw DocumentStorageError.fileTooLarge(limit: maximumFileSize)
        }
        let decoded = try decodeContents(data, fallbackEncoding: fallbackEncoding)
        return TextFile(text: decoded.text, encoding: decoded.encoding,
                        hasBOM: decoded.hasBOM, originalData: data)
    }

    /// Saves exactly the supplied text; `lineEnding` is metadata, not a conversion request.
    /// New files default to UTF-8 without a BOM. Encoding failures leave the destination intact.
    ///
    /// `expected` is the complete previously read data, including any BOM. A missing file is
    /// a conflict even when `expected` is empty. When omitted, a format read from this same URL
    /// supplies its snapshot automatically. A different destination (Save As), or no format,
    /// has no implicit snapshot; pass `expected` to protect an existing destination there.
    ///
    /// The content comparison immediately before an atomic write is optimistic concurrency,
    /// not a cross-process compare-and-swap: an uncoordinated writer can still race the replace.
    /// POSIX mode bits are explicitly restored after replacement. If restoration fails, the
    /// error states that content has already been saved; it must not be treated as a rollback.
    public static func encodedData(_ text:String,format:TextFile?) throws -> Data { try encode(text,encoding:try supportedEncoding(format?.encoding ?? .utf8),hasBOM:format?.hasBOM ?? false) }

    @discardableResult
    public static func write(
        text: String,
        to url: URL,
        format: TextFile? = nil,
        expected: Data? = nil
    ) throws -> TextFile {
        let target = try resolvedFileURL(url)
        let encoding = try supportedEncoding(format?.encoding ?? .utf8)
        let hasBOM = format?.hasBOM ?? false
        let data = try encode(text, encoding: encoding, hasBOM: hasBOM)
        guard data.count <= maximumFileSize else {
            throw DocumentStorageError.fileTooLarge(limit: maximumFileSize)
        }

        let expectedData = expected ?? (format?.sourceURL == target ? format?.fingerprint : nil)
        let attributes = try attributesIfPresent(at: target)
        if let attributes {
            try requireRegularFile(attributes, at: target)
        }
        let permissions = attributes?[.posixPermissions]

        // Read into owned memory: a mapped snapshot could change under an in-place writer.
        let current: Data?
        do {
            current = attributes == nil ? nil : try readBytes(at: target)
        } catch where expectedData != nil && isMissingFile(error) {
            throw DocumentStorageError.externalChange(url)
        }
        if let expectedData, current != expectedData {
            throw DocumentStorageError.externalChange(url)
        }

        // This also retains the inode and timestamp for a genuinely unmodified document.
        // Compare bytes, never String equality (which treats canonical Unicode forms as equal).
        if current != data {
            try data.write(to: target, options: .atomic)
            if let permissions {
                do {
                    try FileManager.default.setAttributes([.posixPermissions: permissions],
                                                          ofItemAtPath: target.path)
                } catch {
                    throw DocumentStorageError.permissionsNotPreserved(url, reason: error.localizedDescription)
                }
            }
        }
        return snapshot(text: text, encoding: encoding, hasBOM: hasBOM, data: data, url: target)
    }

    private static func resolvedFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw DocumentStorageError.notFileURL(url) }
        // Preserve a symlink itself when saving a document opened through it.
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func attributesIfPresent(at url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch where isMissingFile(error) {
            return nil
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }

    private static func requireRegularFile(_ attributes: [FileAttributeKey: Any], at url: URL) throws {
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DocumentStorageError.notRegularFile(url)
        }
    }

    private static func readBytes(at url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try requireRegularFile(attributes, at: url)
        if let size = attributes[.size] as? NSNumber, size.uint64Value > UInt64(maximumFileSize) {
            throw DocumentStorageError.fileTooLarge(limit: maximumFileSize)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            // Bound allocation even when the file grows after the metadata check.
            let count = min(1_024 * 1_024, maximumFileSize - data.count + 1)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            guard chunk.count <= maximumFileSize - data.count else {
                throw DocumentStorageError.fileTooLarge(limit: maximumFileSize)
            }
            data.append(chunk)
        }
        return data
    }

    // Ordering matters: the UTF-32LE prefix contains the entire UTF-16LE BOM.
    private static let byteOrderMarks: [(encoding: String.Encoding, bytes: Data)] = [
        (.utf32LittleEndian, Data([0xFF, 0xFE, 0x00, 0x00])),
        (.utf32BigEndian, Data([0x00, 0x00, 0xFE, 0xFF])),
        (.utf8, Data([0xEF, 0xBB, 0xBF])),
        (.utf16LittleEndian, Data([0xFF, 0xFE])),
        (.utf16BigEndian, Data([0xFE, 0xFF]))
    ]

    private static func supportedEncoding(_ encoding: String.Encoding) throws -> String.Encoding {
        switch encoding {
        case .utf16: return .utf16LittleEndian
        case .utf32: return .utf32LittleEndian
        case .utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian,
             .ascii, .windowsCP1252, .isoLatin1, .macOSRoman:
            return encoding
        default:
            throw DocumentStorageError.unsupportedEncoding(encoding)
        }
    }

    private static func decodeContents(
        _ data: Data,
        fallbackEncoding: String.Encoding?
    ) throws -> (text: String, encoding: String.Encoding, hasBOM: Bool) {
        if let mark = byteOrderMarks.first(where: { data.starts(with: $0.bytes) }) {
            // A marked but malformed file must never fall back to a permissive legacy codec.
            let payload = Data(data.dropFirst(mark.bytes.count))
            guard let text = exactDecode(payload, encoding: mark.encoding) else {
                throw DocumentStorageError.invalidEncoding
            }
            try requireText(text)
            return (text, mark.encoding, true)
        }
        if let text = exactDecode(data, encoding: .utf8) {
            try requireText(text)
            return (text, .utf8, false)
        }
        guard let fallbackEncoding else { throw DocumentStorageError.invalidEncoding }
        let encoding = try supportedEncoding(fallbackEncoding)
        guard let text = exactDecode(data, encoding: encoding) else {
            throw DocumentStorageError.invalidEncoding
        }
        try requireText(text)
        return (text, encoding, false)
    }

    private static func exactDecode(_ data: Data, encoding: String.Encoding) -> String? {
        guard let text = String(data: data, encoding: encoding),
              let roundTrip = text.data(using: encoding, allowLossyConversion: false),
              roundTrip == data else { return nil }
        return text
    }

    private static func requireText(_ text: String) throws {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0...8, 14...31, 127...132, 134...159:
                throw DocumentStorageError.binaryFile
            default:
                break // Allow tab, LF, VT, FF, CR and Unicode's next-line character.
            }
        }
    }

    private static func encode(_ text: String, encoding: String.Encoding, hasBOM: Bool) throws -> Data {
        try requireText(text)
        guard let payload = text.data(using: encoding, allowLossyConversion: false),
              let decoded = exactDecode(payload, encoding: encoding),
              decoded.utf8.elementsEqual(text.utf8) else {
            throw DocumentStorageError.unrepresentableText(encoding)
        }
        guard hasBOM else { return payload }
        guard let mark = byteOrderMarks.first(where: { $0.encoding == encoding }) else {
            throw DocumentStorageError.unsupportedBOM(encoding)
        }
        var data = mark.bytes
        data.append(payload)
        return data
    }

    private static func snapshot(
        text: String, encoding: String.Encoding, hasBOM: Bool, data: Data, url: URL
    ) -> TextFile {
        var file = TextFile(text: text, encoding: encoding, hasBOM: hasBOM, originalData: data)
        file.sourceURL = url
        return file
    }

    fileprivate static func newlineStyle(in text: String) -> (preferred: String, mixed: Bool) {
        let endings = ["\n", "\r\n", "\r"]
        var counts = [0, 0, 0]
        var order = [Int]()
        var iterator = text.utf8.makeIterator()
        var current = iterator.next()
        while let byte = current {
            let kind: Int
            if byte == 13 {
                current = iterator.next()
                if current == 10 {
                    kind = 1
                    current = iterator.next()
                } else {
                    kind = 2
                }
            } else {
                current = iterator.next()
                guard byte == 10 else { continue }
                kind = 0
            }
            if counts[kind] == 0 { order.append(kind) }
            counts[kind] += 1
        }
        var preferred = order.first ?? 0
        for kind in order where counts[kind] > counts[preferred] { preferred = kind }
        return (endings[preferred], order.count > 1)
    }
}
