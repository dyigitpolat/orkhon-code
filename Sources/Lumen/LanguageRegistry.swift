import Foundation

/// A generated SciTE language profile. Keyword array indices are Scintilla word
/// list indices (0...8); empty strings preserve unused slots.
struct Language: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let lexer: String
    /// Lowercase extensions without a dot, including compound suffixes.
    let extensions: [String]
    let filenames: [String]
    let keywords: [String]
    /// Pass each entry to the Lexilla bridge's property setter.
    let properties: [String: String]

    var id: String { name }
}

/// Loads the generated Bundle.main resource on first use. The lock protects both
/// lazy decoding and index creation, including calls from background readers.
final class LanguageRegistry: @unchecked Sendable {
    static let shared = LanguageRegistry()

    private let bundle: Bundle
    private let lock = NSLock()
    private var cachedIndex: Index?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Also useful for previews/tests that do not run in the application bundle.
    init(languages: [Language]) {
        bundle = .main
        cachedIndex = Index(languages: languages)
    }

    var languages: [Language] { index.languages }

    /// Exact filenames win, then the longest known extension, then a shebang.
    /// Untitled/unknown files return nil unless their interpreter is recognized.
    func language(for url: URL?, text: String) -> Language? {
        let lookup = index
        if let filename = url?.lastPathComponent, !filename.isEmpty {
            if let language = lookup.filenames[filename] ?? lookup.foldedFilenames[filename.lowercased()] {
                return language
            }
            let lower = filename.lowercased()
            // Start at the first dot: .cmake.in must take precedence over .in.
            for position in lower.indices where lower[position] == "." {
                let suffix = String(lower[lower.index(after: position)...])
                if let language = lookup.extensions[suffix] {
                    return language
                }
            }
        }
        guard let interpreter = Self.interpreter(in: text) else { return nil }
        let suffix: String
        switch interpreter {
        case "sh", "bash", "zsh", "ksh", "dash", "ash": suffix = "sh"
        case "python", "pythonw", "pypy": suffix = "py"
        case "ruby", "jruby": suffix = "rb"
        case "perl": suffix = "pl"
        case "raku", "perl6": suffix = "raku"
        case "node", "nodejs", "bun", "qjs", "d8": suffix = "js"
        case "deno", "ts-node", "tsx": suffix = "ts"
        case "swift": suffix = "swift"
        case "lua", "luajit": suffix = "lua"
        case "php": suffix = "php"
        case "rscript": suffix = "r"
        case "tclsh", "wish": suffix = "tcl"
        case "awk", "gawk", "mawk", "nawk": suffix = "awk"
        case "pwsh", "powershell": suffix = "ps1"
        case "runhaskell", "runghc": suffix = "hs"
        case "guile", "racket", "scheme": suffix = "scm"
        case "sbcl", "clisp": suffix = "lisp"
        case "ocaml": suffix = "ml"
        case "escript": suffix = "erl"
        case "elixir": suffix = "ex"
        case "groovy": suffix = "groovy"
        case "julia": suffix = "jl"
        case "dart": suffix = "dart"
        default: return nil
        }
        return lookup.extensions[suffix]
    }

    private var index: Index {
        lock.lock()
        defer { lock.unlock() }
        if let cachedIndex { return cachedIndex }
        let loaded: [Language]
        do {
            // Support both a flat app Resources directory and a preserved folder.
            guard let url = bundle.url(forResource: "languages", withExtension: "json")
                ?? bundle.url(forResource: "languages", withExtension: "json", subdirectory: "Resources") else {
                throw RegistryError.missingResource
            }
            loaded = try JSONDecoder().decode([Language].self, from: Data(contentsOf: url))
        } catch {
            NSLog("Lumen could not load languages.json: %@", String(describing: error))
            loaded = []
        }
        let built = Index(languages: loaded)
        cachedIndex = built
        return built
    }

    private enum RegistryError: Error { case missingResource }

    private struct Index {
        let languages: [Language]
        var filenames: [String: Language] = [:]
        var foldedFilenames: [String: Language] = [:]
        var extensions: [String: Language] = [:]

        init(languages: [Language]) {
            self.languages = languages.sorted {
                let lhs = $0.name.lowercased(), rhs = $1.name.lowercased()
                return lhs == rhs ? $0.name < $1.name : lhs < rhs
            }
            for language in self.languages {
                for filename in language.filenames {
                    if filenames[filename] == nil { filenames[filename] = language }
                    if foldedFilenames[filename.lowercased()] == nil {
                        foldedFilenames[filename.lowercased()] = language
                    }
                }
                for suffix in language.extensions where extensions[suffix.lowercased()] == nil {
                    extensions[suffix.lowercased()] = language
                }
            }
        }
    }

    private static func interpreter(in text: String) -> String? {
        // Bound work even for a very large document with no newlines.
        var firstLine = String(text.prefix(2048).prefix { !$0.isNewline })
        if firstLine.hasPrefix("\u{FEFF}") { firstLine.removeFirst() }
        guard firstLine.hasPrefix("#!") else { return nil }
        var tokens = shellWords(String(firstLine.dropFirst(2)))
        guard !tokens.isEmpty else { return nil }
        var command = (tokens.removeFirst() as NSString).lastPathComponent.lowercased()
        if command == "env" {
            // env [-S|--split-string] [-u NAME] [NAME=value ...] interpreter.
            while let token = tokens.first {
                tokens.removeFirst()
                if token == "--" { break }
                if ["-u", "--unset", "-C", "--chdir", "-a", "--argv0"].contains(token) {
                    if !tokens.isEmpty { tokens.removeFirst() }
                    continue
                }
                if token == "-S" || token == "--split-string" {
                    if let first = tokens.first, first.contains(where: \.isWhitespace) {
                        tokens = shellWords(tokens.removeFirst()) + tokens
                    }
                    continue
                }
                if token.hasPrefix("--split-string=") {
                    tokens = shellWords(String(token.dropFirst("--split-string=".count))) + tokens
                    continue
                }
                if token.hasPrefix("-") || token.contains("=") { continue }
                tokens.insert(token, at: 0)
                break
            }
            guard let executable = tokens.first else { return nil }
            command = (executable as NSString).lastPathComponent.lowercased()
        }
        // Only recognized versioned interpreters lose their numeric suffix;
        // perl6 is a distinct language and must retain its name.
        for prefix in ["python", "pythonw", "pypy", "ruby", "perl", "lua", "php", "tclsh", "wish"] {
            if command == "perl6" { break }
            if command.hasPrefix(prefix) {
                let version = command.dropFirst(prefix.count)
                if !version.isEmpty, version.first?.isNumber == true,
                   version.allSatisfy({ $0.isNumber || $0 == "." }) {
                    return prefix
                }
            }
        }
        return command
    }

    /// Tokenize quotes/escapes in an env shebang without invoking a shell.
    private static func shellWords(_ input: String) -> [String] {
        var words: [String] = [], word = ""
        var quote: Character?, escaped = false
        for character in input {
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !word.isEmpty { words.append(word); word = "" }
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }
}
