import Foundation
import XCTest
import LumenCore

final class DocumentStorageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumenStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private var url: URL { directory.appendingPathComponent("document.txt") }

    private func put(_ data: Data, at target: URL? = nil) throws {
        try data.write(to: target ?? url)
    }

    private func assertStorageError<T>(
        _ expected: DocumentStorageError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? DocumentStorageError, expected, file: file, line: line)
        }
    }

    func testDefaultSaveIsUTF8WithoutBOMAndReturnsSnapshot() throws {
        let text = "Hello, café — 日本語 🙂 e\u{301}\n"
        let saved = try DocumentStorage.write(text: text, to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8))
        XCTAssertEqual(saved.encoding, .utf8)
        XCTAssertFalse(saved.hasBOM)
        XCTAssertEqual(saved.text, text)
        XCTAssertEqual(saved.originalData, Data(text.utf8))
        XCTAssertEqual(saved.fingerprint, saved.originalData)
        XCTAssertEqual(try DocumentStorage.read(url).fingerprint, saved.fingerprint)
    }

    func testEmptyFileRoundTrip() throws {
        try put(Data())
        let file = try DocumentStorage.read(url)
        XCTAssertEqual(file.text, "")
        XCTAssertEqual(file.lineEnding, "\n")
        XCTAssertFalse(file.hasMixedLineEndings)
        XCTAssertEqual(try DocumentStorage.write(text: "", to: url, format: file).originalData, Data())
    }

    func testRecoveryDecodeRestoresOriginalSnapshotAndDetectsExternalChanges() throws {
        let original = Data([0xFE, 0xFF, 0, 0x41, 0, 13, 0, 10])
        let recovered = try DocumentStorage.decode(original)
        XCTAssertEqual(recovered.text, "A\r\n")
        XCTAssertEqual(recovered.encoding, .utf16BigEndian)
        XCTAssertTrue(recovered.hasBOM)
        XCTAssertEqual(recovered.lineEnding, "\r\n")
        XCTAssertEqual(recovered.originalData, original)
        XCTAssertEqual(recovered.fingerprint, original)

        try put(original)
        let saved = try DocumentStorage.write(text: "Recovered edit\r\n", to: url,
                                             format: recovered, expected: recovered.fingerprint)
        XCTAssertEqual(try DocumentStorage.read(url).originalData, saved.originalData)
        let external = Data("changed outside editor".utf8)
        try put(external)
        assertStorageError(.externalChange(url)) {
            try DocumentStorage.write(text: "Recovered edit\r\n", to: url,
                                      format: recovered, expected: recovered.fingerprint)
        }
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    func testRecoveryDecodeUsesTheSameStrictEncodingAndBinaryChecksAsRead() throws {
        assertStorageError(.invalidEncoding) { try DocumentStorage.decode(Data([0xC3, 0x28])) }
        assertStorageError(.binaryFile) { try DocumentStorage.decode(Data([0x41, 0, 0x42])) }
        let recovered = try DocumentStorage.decode(Data([0x63, 0x61, 0x66, 0xE9]),
                                                  fallbackEncoding: .windowsCP1252)
        XCTAssertEqual(recovered.text, "café")
        XCTAssertEqual(recovered.encoding, .windowsCP1252)
    }

    func testEveryUnicodeBOMRoundTripsAndSurvivesEditing() throws {
        let cases: [(String.Encoding, [UInt8])] = [
            (.utf8, [0xEF, 0xBB, 0xBF]),
            (.utf16LittleEndian, [0xFF, 0xFE]),
            (.utf16BigEndian, [0xFE, 0xFF]),
            (.utf32LittleEndian, [0xFF, 0xFE, 0, 0]),
            (.utf32BigEndian, [0, 0, 0xFE, 0xFF])
        ]
        let original = "Aé🙂\r\n終\nlast\r"
        for (encoding, mark) in cases {
            let data = Data(mark) + (try XCTUnwrap(original.data(using: encoding)))
            try put(data)
            let file = try DocumentStorage.read(url)
            XCTAssertEqual(file.encoding, encoding)
            XCTAssertTrue(file.hasBOM)
            XCTAssertEqual(file.text.utf8.map { $0 }, Array(original.utf8))
            XCTAssertTrue(file.hasMixedLineEndings)
            let unchanged = try DocumentStorage.write(text: original, to: url, format: file)
            XCTAssertEqual(unchanged.originalData, data)
            XCTAssertEqual(try Data(contentsOf: url), data)

            let edited = original + "編集 🦉"
            let saved = try DocumentStorage.write(text: edited, to: url, format: unchanged,
                                                 expected: unchanged.fingerprint)
            let editedData = Data(mark) + (try XCTUnwrap(edited.data(using: encoding)))
            XCTAssertEqual(saved.originalData, editedData)
            XCTAssertEqual(try Data(contentsOf: url), editedData)
            XCTAssertEqual(try DocumentStorage.read(url).text, edited)
        }
    }

    func testBOMOnlyFilesAndLiteralLeadingBOM() throws {
        for (encoding, mark) in [
            (String.Encoding.utf8, Data([0xEF, 0xBB, 0xBF])),
            (.utf16LittleEndian, Data([0xFF, 0xFE])),
            (.utf16BigEndian, Data([0xFE, 0xFF])),
            (.utf32LittleEndian, Data([0xFF, 0xFE, 0, 0])),
            (.utf32BigEndian, Data([0, 0, 0xFE, 0xFF]))
        ] {
            try put(mark)
            let empty = try DocumentStorage.read(url)
            XCTAssertEqual(empty.text, "")
            XCTAssertEqual(empty.encoding, encoding)
            XCTAssertEqual(try DocumentStorage.write(text: "", to: url, format: empty).originalData, mark)
        }
        let doubleMark = Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF]) + Data("content".utf8)
        try put(doubleMark)
        let file = try DocumentStorage.read(url)
        XCTAssertEqual(file.text, "\u{FEFF}content")
        XCTAssertEqual(try DocumentStorage.write(text: file.text, to: url, format: file).originalData, doubleMark)
    }

    func testNewlineDetectionDoesNotChangeText() throws {
        let cases: [(String, String, Bool)] = [
            ("no endings", "\n", false), ("a\nb\n", "\n", false),
            ("a\r\nb\r\n", "\r\n", false), ("a\rb\r", "\r", false),
            ("a\r\nb\nc\r", "\r\n", true),
            ("a\rb\nc\n", "\n", true), ("\r\r\n\n", "\r", true)
        ]
        for (text, preferred, mixed) in cases {
            try put(Data(text.utf8))
            let file = try DocumentStorage.read(url)
            XCTAssertEqual(file.lineEnding, preferred)
            XCTAssertEqual(file.hasMixedLineEndings, mixed)
            let saved = try DocumentStorage.write(text: text + "edited\n", to: url, format: file)
            XCTAssertEqual(saved.originalData, Data((text + "edited\n").utf8))
        }
    }

    func testLineEndingMetadataNeverRewritesTheEditorBuffer() throws {
        let format = TextFile(text: "", lineEnding: "\r\n")
        let text = "one\ntwo\rthree\r\nfour"
        try DocumentStorage.write(text: text, to: url, format: format)
        XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8))
    }

    func testCanonicalUnicodeChangeIsNotMistakenForUnchangedText() throws {
        let composed = "caf\u{E9}\n"
        let decomposed = "cafe\u{301}\n"
        XCTAssertEqual(composed, decomposed) // Swift String equality is canonically equivalent.
        try put(Data(composed.utf8))
        let file = try DocumentStorage.read(url)
        try DocumentStorage.write(text: decomposed, to: url, format: file)
        XCTAssertEqual(try Data(contentsOf: url), Data(decomposed.utf8))
    }

    func testMutatingSnapshotTextDoesNotReuseStaleOriginalBytes() throws {
        try put(Data("before".utf8))
        var file = try DocumentStorage.read(url)
        file.text = "after"
        let saved = try DocumentStorage.write(text: file.text, to: url, format: file)
        XCTAssertEqual(saved.originalData, Data("after".utf8))
        XCTAssertEqual(try Data(contentsOf: url), saved.originalData)
    }

    func testChangingFormatWithUnchangedTextAppliesEncodingAndBOM() throws {
        try put(Data("café".utf8))
        var file = try DocumentStorage.read(url)
        file.encoding = .utf16BigEndian
        file.hasBOM = true
        let saved = try DocumentStorage.write(text: file.text, to: url, format: file)
        XCTAssertEqual(saved.encoding, .utf16BigEndian)
        XCTAssertEqual(saved.originalData, Data([0xFE, 0xFF, 0, 0x63, 0, 0x61, 0, 0x66, 0, 0xE9]))
    }

    func testLegacyEncodingRequiresExplicitFallback() throws {
        let data = Data([0x93, 0x63, 0x61, 0x66, 0xE9, 0x94, 0x20, 0x80, 0x0D, 0x0A])
        try put(data)
        assertStorageError(.invalidEncoding) { try DocumentStorage.read(url) }
        let file = try DocumentStorage.read(url, fallbackEncoding: .windowsCP1252)
        XCTAssertEqual(file.text, "“café” €\r\n")
        XCTAssertEqual(file.encoding, .windowsCP1252)
        XCTAssertFalse(file.hasBOM)
        XCTAssertEqual(try DocumentStorage.write(text: file.text, to: url, format: file).originalData, data)
    }

    func testLatin1AndMacRomanRoundTripWithExplicitFallback() throws {
        for encoding in [String.Encoding.isoLatin1, .macOSRoman] {
            let text = "café\r"
            let data = try XCTUnwrap(text.data(using: encoding))
            try put(data)
            let file = try DocumentStorage.read(url, fallbackEncoding: encoding)
            XCTAssertEqual(file.text, text)
            XCTAssertEqual(file.encoding, encoding)
            XCTAssertEqual(try DocumentStorage.write(text: text, to: url, format: file).originalData, data)
        }
    }

    func testFallbackNeverOverridesValidUTF8OrABOM() throws {
        try put(Data("café".utf8))
        XCTAssertEqual(try DocumentStorage.read(url, fallbackEncoding: .isoLatin1).encoding, .utf8)
        try put(Data([0xFE, 0xFF, 0, 0x41]))
        XCTAssertEqual(try DocumentStorage.read(url, fallbackEncoding: .isoLatin1).encoding, .utf16BigEndian)
    }

    func testUnrepresentableEditDoesNotModifyDestination() throws {
        let data = Data([0x63, 0x61, 0x66, 0xE9])
        try put(data)
        let file = try DocumentStorage.read(url, fallbackEncoding: .windowsCP1252)
        assertStorageError(.unrepresentableText(.windowsCP1252)) {
            try DocumentStorage.write(text: file.text + "🙂", to: url, format: file)
        }
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testMalformedUnicodeIsRejectedWithoutLegacyFallback() throws {
        let malformed: [Data] = [
            Data([0xC3, 0x28]), Data([0xC0, 0xAF]), Data([0xE2, 0x82]),
            Data([0xEF, 0xBB, 0xBF, 0xFF]),
            Data([0xFF, 0xFE, 0x41]), Data([0xFE, 0xFF, 0xD8, 0x00]),
            Data([0xFF, 0xFE, 0x00, 0xDC]),
            Data([0xFF, 0xFE, 0, 0, 0, 0xD8, 0, 0]),
            Data([0, 0, 0xFE, 0xFF, 0, 0x11, 0, 0]),
            Data([0, 0, 0xFE, 0xFF, 0, 0, 0x41])
        ]
        for data in malformed {
            try put(data)
            assertStorageError(.invalidEncoding) { try DocumentStorage.read(url) }
        }
        try put(Data([0xFF, 0xFE, 0x41]))
        assertStorageError(.invalidEncoding) { try DocumentStorage.read(url, fallbackEncoding: .isoLatin1) }
    }

    func testBinaryControlCharactersAreRejectedInEveryEncoding() throws {
        for text in ["hello\0world", "\u{7}bell", "\u{1B}[31m", "delete\u{7F}", "\u{81}"] {
            try put(Data(text.utf8))
            assertStorageError(.binaryFile) { try DocumentStorage.read(url) }
        }
        try put(Data([0xFF, 0xFE, 0x41, 0, 0, 0, 0x42, 0]))
        assertStorageError(.binaryFile) { try DocumentStorage.read(url) }
        try put(Data([0xE9, 0x00]))
        assertStorageError(.binaryFile) { try DocumentStorage.read(url, fallbackEncoding: .isoLatin1) }
    }

    func testCommonBinaryHeadersCannotOpenAsText() throws {
        for data in [
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            Data([0x50, 0x4B, 0x03, 0x04, 0, 0]),
            Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0, 0, 0])
        ] {
            try put(data)
            XCTAssertThrowsError(try DocumentStorage.read(url))
        }
    }

    func testTextWhitespaceIsAccepted() throws {
        let text = "\tindent\n\r\u{B}\u{C}\u{85}日本語"
        try put(Data(text.utf8))
        XCTAssertEqual(try DocumentStorage.read(url).text, text)
    }

    func testInvalidSaveFormatOrBinaryTextLeavesExistingFileIntact() throws {
        let data = Data("original".utf8)
        try put(data)
        assertStorageError(.binaryFile) { try DocumentStorage.write(text: "bad\0text", to: url) }
        assertStorageError(.unsupportedEncoding(.shiftJIS)) {
            try DocumentStorage.write(text: "text", to: url, format: TextFile(text: "", encoding: .shiftJIS))
        }
        assertStorageError(.unsupportedBOM(.isoLatin1)) {
            try DocumentStorage.write(text: "text", to: url,
                                      format: TextFile(text: "", encoding: .isoLatin1, hasBOM: true))
        }
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testExternalChangeWithSameLengthAndTimestampIsDetected() throws {
        try put(Data("first".utf8))
        let file = try DocumentStorage.read(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try put(Data("other".utf8))
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(attributes[.modificationDate])],
                                              ofItemAtPath: url.path)
        assertStorageError(.externalChange(url)) {
            try DocumentStorage.write(text: "my edit", to: url, format: file, expected: file.fingerprint)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("other".utf8))
    }

    func testSameFileFormatAutomaticallyProtectsItsSnapshotEvenWithoutEdits() throws {
        try put(Data("before".utf8))
        let file = try DocumentStorage.read(url)
        try put(Data("external".utf8))
        assertStorageError(.externalChange(url)) {
            try DocumentStorage.write(text: file.text, to: url, format: file)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("external".utf8))
    }

    func testDeletedFileIsAConflictAndIsNotRecreated() throws {
        try put(Data("before".utf8))
        let file = try DocumentStorage.read(url)
        try FileManager.default.removeItem(at: url)
        assertStorageError(.externalChange(url)) {
            try DocumentStorage.write(text: "after", to: url, format: file)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEmptyExpectedDataRequiresAnExistingEmptyFile() throws {
        assertStorageError(.externalChange(url)) {
            try DocumentStorage.write(text: "new", to: url, expected: Data())
        }
        try put(Data())
        XCTAssertEqual(try DocumentStorage.write(text: "new", to: url, expected: Data()).text, "new")
    }

    func testExplicitExpectedOverridesFormatSnapshot() throws {
        try put(Data("old".utf8))
        let file = try DocumentStorage.read(url)
        let accepted = Data("accepted external edit".utf8)
        try put(accepted)
        let saved = try DocumentStorage.write(text: "merged", to: url, format: file, expected: accepted)
        XCTAssertEqual(saved.originalData, Data("merged".utf8))
    }

    func testSaveAsRetainsEncodingWithoutComparingAgainstTheSourceFile() throws {
        let data = Data([0xFE, 0xFF, 0, 0x41, 0, 13, 0, 10])
        try put(data)
        let file = try DocumentStorage.read(url)
        let destination = directory.appendingPathComponent("copy.txt")
        let saved = try DocumentStorage.write(text: file.text, to: destination, format: file)
        XCTAssertEqual(saved.originalData, data)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try Data(contentsOf: destination), data)

        try put(Data("external".utf8), at: destination)
        assertStorageError(.externalChange(destination)) {
            try DocumentStorage.write(text: "edit", to: destination, format: saved)
        }
    }

    func testReturnedSnapshotSupportsRepeatedSaves() throws {
        let first = try DocumentStorage.write(text: "one", to: url)
        let second = try DocumentStorage.write(text: "two", to: url, format: first)
        let third = try DocumentStorage.write(text: "three", to: url, format: second)
        XCTAssertEqual(third.fingerprint, Data("three".utf8))
        assertStorageError(.externalChange(url)) {
            try DocumentStorage.write(text: "stale", to: url, format: first)
        }
    }

    func testUnchangedSavePreservesBytesInodeTimestampAndPermissions() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\nc\r".utf8)
        try put(data)
        try FileManager.default.setAttributes([.posixPermissions: 0o640,
                                              .modificationDate: Date(timeIntervalSince1970: 1_000)],
                                             ofItemAtPath: url.path)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let file = try DocumentStorage.read(url)
        try DocumentStorage.write(text: file.text, to: url, format: file)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(after[.posixPermissions] as? NSNumber, NSNumber(value: 0o640))
    }

    func testAtomicSaveReplacesInodePreservesPermissionsAndLeavesHardLinkUntouched() throws {
        let original = Data("old contents".utf8)
        try put(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: url.path)
        let link = directory.appendingPathComponent("original-hard-link.txt")
        try FileManager.default.linkItem(at: url, to: link)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let file = try DocumentStorage.read(url)
        let edited = String(repeating: "new — 🙂\r\n", count: 4_096)
        try DocumentStorage.write(text: edited, to: url, format: file)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), Data(edited.utf8))
        XCTAssertEqual(try Data(contentsOf: link), original)
        XCTAssertNotEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(after[.posixPermissions] as? NSNumber, NSNumber(value: 0o751))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set([url.lastPathComponent, link.lastPathComponent]))
    }

    func testSymlinkSaveUpdatesTargetAndPreservesLink() throws {
        try put(Data("before".utf8))
        let link = directory.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let file = try DocumentStorage.read(link)
        try DocumentStorage.write(text: "after", to: link, format: file)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), url.path)
        XCTAssertEqual(try Data(contentsOf: url), Data("after".utf8))
        XCTAssertEqual(try Data(contentsOf: link), Data("after".utf8))
    }

    func testReadSnapshotDoesNotChangeWhenDiskIsOverwrittenInPlace() throws {
        let original = Data(String(repeating: "a", count: 32_768).utf8)
        try put(original)
        let file = try DocumentStorage.read(url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(String(repeating: "b", count: original.count).utf8))
        try handle.close()
        XCTAssertEqual(file.originalData, original)
        assertStorageError(.externalChange(url)) {
            try DocumentStorage.write(text: "edit", to: url, expected: file.fingerprint)
        }
    }

    func testOversizedSparseFileIsRejectedWithoutReadingItIntoMemory() throws {
        try put(Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(DocumentStorage.maximumFileSize) + 1)
        try handle.close()
        assertStorageError(.fileTooLarge(limit: DocumentStorage.maximumFileSize)) {
            try DocumentStorage.read(url)
        }
        assertStorageError(.fileTooLarge(limit: DocumentStorage.maximumFileSize)) {
            try DocumentStorage.write(text: "do not truncate", to: url)
        }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        XCTAssertEqual(size?.intValue, DocumentStorage.maximumFileSize + 1)
    }

    func testNonFileURLsAndDirectoriesAreRejected() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.com/document.txt"))
        assertStorageError(.notFileURL(remote)) { try DocumentStorage.read(remote) }
        assertStorageError(.notFileURL(remote)) { try DocumentStorage.write(text: "text", to: remote) }
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        assertStorageError(.notRegularFile(resolvedDirectory)) { try DocumentStorage.read(directory) }
        assertStorageError(.notRegularFile(resolvedDirectory)) {
            try DocumentStorage.write(text: "text", to: directory)
        }
    }

    func testFailedSaveToMissingParentDoesNotDamageOtherFiles() throws {
        let original = Data("original".utf8)
        try put(original)
        let missing = directory.appendingPathComponent("missing/document.txt")
        XCTAssertThrowsError(try DocumentStorage.write(text: "new", to: missing))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
