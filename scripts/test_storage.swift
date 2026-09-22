#!/usr/bin/env swift
// From the workspace root:
// swift -module-cache-path "$PWD/work/module-cache" scripts/test_storage.swift
//
// Executes the actual DocumentStorageTests methods with Foundation-only assertions.
// This is a standalone validation harness, not the XCTest runtime. It requires no
// SwiftPM manifest, Xcode, Python, dependencies, or changes to the checked-in tests.
// stdout is one JSON result; compiler diagnostics go to stderr. Exit codes:
// 0 = all cases passed, 1 = assertion/test failures, 2 = harness/compiler failure.

import Foundation

struct HarnessError: Error, CustomStringConvertible {
    let description: String
}

func runProcess(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    // Keep stdout machine-readable, including when the compiler fails.
    process.standardOutput = FileHandle.standardError
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

func validateStorage() throws -> Int32 {
    let manager = FileManager.default
    let root = URL(fileURLWithPath: #filePath).standardizedFileURL
        .deletingLastPathComponent().deletingLastPathComponent()
    let productionURL = root.appendingPathComponent("Sources/LumenCore/DocumentStorage.swift")
    let testsURL = root.appendingPathComponent("Tests/LumenCoreTests/DocumentStorageTests.swift")
    let scratch = root.appendingPathComponent("work/storage-tests", isDirectory: true)
    let runDirectory = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = root.appendingPathComponent("work/module-cache", isDirectory: true)
        .resolvingSymlinksInPath()
    try manager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: runDirectory) }
    try manager.createDirectory(at: cache, withIntermediateDirectories: true)

    var source = try String(contentsOf: testsURL, encoding: .utf8)
    let methods = try NSRegularExpression(pattern: #"(?m)^    func (test[A-Za-z0-9_]+)\(\) throws \{"#)
    let declarations = try NSRegularExpression(pattern: #"(?m)^\s*func (test[A-Za-z0-9_]+)\s*\("#)
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    let matches = methods.matches(in: source, range: range)
    let names = matches.compactMap { match -> String? in
        guard let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }
    guard !names.isEmpty, Set(names).count == names.count,
          names.count == declarations.numberOfMatches(in: source, range: range) else {
        throw HarnessError(description: "Test discovery requires unique synchronous 'func testName() throws' methods; refusing to skip tests.")
    }

    // Preserve original line numbers so JSON failures point to the maintained test file.
    let replacements = [
        ("import XCTest", "// XCTest assertions supplied by the standalone harness."),
        ("import LumenCore", "// DocumentStorage.swift is compiled into this executable."),
        ("final class DocumentStorageTests: XCTestCase {", "final class DocumentStorageTests {"),
        ("override func setUpWithError()", "func setUpWithError()"),
        ("override func tearDownWithError()", "func tearDownWithError()")
    ]
    for (before, after) in replacements {
        guard source.components(separatedBy: before).count == 2 else {
            throw HarnessError(description: "Unexpected test structure for '\(before)'; update the harness before running.")
        }
        source = source.replacingOccurrences(of: before, with: after)
    }
    source = "#sourceLocation(file: \(String(reflecting: testsURL.path)), line: 1)\n" + source

    let assertions = #"""
    import Foundation

    struct ValidationIssue: Encodable {
        let test: String
        let file: String
        let line: UInt
        let message: String
    }
    struct UnwrapFailure: Error {}
    var issues: [ValidationIssue] = []
    var currentTest = ""

    func recordFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        issues.append(ValidationIssue(test: currentTest, file: String(describing: file),
                                      line: line, message: message))
    }
    func XCTAssertEqual<T: Equatable>(
        _ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            let left = try lhs(), right = try rhs()
            if left != right { recordFailure("\(left) != \(right)", file: file, line: line) }
        } catch { recordFailure("Unexpected error: \(error)", file: file, line: line) }
    }
    func XCTAssertNotEqual<T: Equatable>(
        _ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            if try lhs() == rhs() { recordFailure("Values unexpectedly equal", file: file, line: line) }
        } catch { recordFailure("Unexpected error: \(error)", file: file, line: line) }
    }
    func XCTAssertTrue(
        _ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            if try !value() { recordFailure("Expected true", file: file, line: line) }
        } catch { recordFailure("Unexpected error: \(error)", file: file, line: line) }
    }
    func XCTAssertFalse(
        _ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            if try value() { recordFailure("Expected false", file: file, line: line) }
        } catch { recordFailure("Unexpected error: \(error)", file: file, line: line) }
    }
    func XCTAssertThrowsError<T>(
        _ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line,
        _ handler: (Error) -> Void = { _ in }
    ) {
        do {
            _ = try expression()
            recordFailure("Expected an error", file: file, line: line)
        } catch { handler(error) }
    }
    func XCTUnwrap<T>(
        _ expression: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line
    ) throws -> T {
        guard let value = try expression() else {
            recordFailure("Expected non-nil", file: file, line: line)
            throw UnwrapFailure()
        }
        return value
    }
    """#

    let cases = names.map { "    (\(String(reflecting: $0)), { try $0.\($0)() })" }.joined(separator: ",\n")
    let runner = #"""
    import Foundation

    let cases: [(name: String, run: (DocumentStorageTests) throws -> Void)] = [
    \#(cases)
    ]
    var passed = 0
    for item in cases {
        currentTest = item.name
        let before = issues.count
        let test = DocumentStorageTests()
        do {
            try test.setUpWithError()
            try item.run(test)
        } catch { recordFailure("Test threw: \(error)") }
        do { try test.tearDownWithError() }
        catch { recordFailure("Cleanup threw: \(error)") }
        if issues.count == before { passed += 1 }
    }
    struct Result: Encodable {
        let runner = "standalone-foundation"
        let suite = "DocumentStorageTests"
        let status: String
        let testsExecuted: Int
        let testsPassed: Int
        let testsFailed: Int
        let assertionFailures: Int
        let failures: [ValidationIssue]
    }
    let result = Result(status: issues.isEmpty ? "passed" : "failed", testsExecuted: cases.count,
                        testsPassed: passed, testsFailed: cases.count - passed,
                        assertionFailures: issues.count, failures: issues)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let output = try encoder.encode(result)
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data([10]))
    exit(issues.isEmpty ? 0 : 1)
    """#

    let assertionsURL = runDirectory.appendingPathComponent("Assertions.swift")
    let transformedTestsURL = runDirectory.appendingPathComponent("StorageTests.swift")
    let runnerURL = runDirectory.appendingPathComponent("main.swift")
    let executable = runDirectory.appendingPathComponent("validate-storage")
    try assertions.write(to: assertionsURL, atomically: true, encoding: .utf8)
    try source.write(to: transformedTestsURL, atomically: true, encoding: .utf8)
    try runner.write(to: runnerURL, atomically: true, encoding: .utf8)

    var environment = ProcessInfo.processInfo.environment
    environment["CLANG_MODULE_CACHE_PATH"] = cache.path
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = cache.path
    let status = try runProcess("/usr/bin/xcrun", [
        "swiftc", "-swift-version", "5", "-module-cache-path", cache.path,
        productionURL.path, assertionsURL.path, transformedTestsURL.path, runnerURL.path,
        "-o", executable.path
    ], environment: environment)
    guard status == 0 else {
        throw HarnessError(description: "swiftc exited with status \(status); see stderr for diagnostics.")
    }

    let process = Process()
    process.executableURL = executable
    process.environment = environment
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

do {
    exit(try validateStorage())
} catch {
    let result = ["runner": "standalone-foundation", "status": "harness-error", "error": String(describing: error)]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    exit(2)
}
