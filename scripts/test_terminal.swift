// Run with scripts/test_terminal.sh. This compiles alongside the production
// TerminalPanel; it does not mock SwiftTerm, AppKit, zsh, or the PTY transport.
// The window is never shown. User shell startup files and history are untouched.
import AppKit
import Darwin
import SwiftTerm

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
private struct TerminalPanelTests {
    private static var checksPassed = 0

    static func main() {
        do {
            try run()
            print("PASS: All \(checksPassed) native terminal runtime checks passed.")
        } catch {
            // run() unwinds its cleanup before a failure is reported or the process exits.
            print("FAIL: \(error)")
            print("RESULT: Failed after \(checksPassed) successful runtime checks.")
            Darwin.exit(1)
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw CheckFailure(description: label) }
        checksPassed += 1
        print("PASS: \(label)")
        fflush(stdout)
    }

    private static func require<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw CheckFailure(description: label) }
        return value
    }

    private static func pumpEvents(for duration: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        while ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func wait(
        _ label: String, timeout: TimeInterval = 8, until condition: () -> Bool
    ) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            pumpEvents(for: 0.02)
        }
        try check(condition(), label)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func terminals(in panel: TerminalPanel) -> [LocalProcessTerminalView] {
        descendants(of: panel).compactMap { $0 as? LocalProcessTerminalView }
    }

    private static func text(in terminal: LocalProcessTerminalView) -> String {
        String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private static func checkPhysicalDirectory(
        _ expected: URL, in terminal: LocalProcessTerminalView, marker: String, label: String
    ) throws {
        // PWD is also provided in the launch environment, so verify the actual process
        // directory with an external pwd. Base64 survives wrapping at spaces in long paths.
        let physicalPath = expected.resolvingSymlinksInPath().path + "\n"
        let encoded = Data(physicalPath.utf8).base64EncodedString()
        terminal.send(txt: "printf '\\n\(marker)_%s\\n' \"$(/bin/pwd -P | /usr/bin/base64)\"\r")
        try wait(label) {
            text(in: terminal).replacingOccurrences(of: "\n", with: "").contains("\(marker)_\(encoded)")
        }
    }

    private static func child(inSession shell: pid_t) -> pid_t? {
        let capacity = max(64, Int(proc_listallpids(nil, 0)) + 64)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return pids.prefix(max(0, min(Int(count), capacity))).first {
            $0 > 1 && $0 != shell && getsid($0) == shell
        }
    }

    private static func isGone(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }

    private static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let manager = FileManager.default
        let scratchRoot = CommandLine.arguments.dropFirst().first.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? manager.temporaryDirectory
        let scratch = scratchRoot.appendingPathComponent("orkhon-terminal-\(UUID().uuidString)", isDirectory: true)
        let cwd = scratch.appendingPathComponent("cwd with 'quotes' $; spaces", isDirectory: true)
        try manager.createDirectory(at: cwd, withIntermediateDirectories: true)
        let openedFile = cwd.appendingPathComponent("welcome.py")
        try "print('directory fixture')\n".write(to: openedFile, atomically: true, encoding: .utf8)
        defer { try? manager.removeItem(at: scratch) }
        let previousZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("ZDOTDIR", scratch.path, 1)
        defer {
            if let previousZdotdir { setenv("ZDOTDIR", previousZdotdir, 1) }
            else { unsetenv("ZDOTDIR") }
        }
        // Deterministic prompt; disable history expansion and background-job renicing.
        // This avoids reading the user's .zshrc and works inside restricted test hosts.
        try "PROMPT='orkhon-test> '; RPROMPT=''; HISTFILE=/dev/null; unsetopt BANG_HIST BGNICE\n"
            .write(to: scratch.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        window.contentView = host
        let panel = TerminalPanel(frame: .zero)
        defer {
            panel.terminateAll()
            pumpEvents(for: 0.8) // Allow SwiftTerm's DispatchIO cleanup and child reaping.
            window.contentView = nil
        }
        try check(!panel.hasRunningSessions && terminals(in: panel).isEmpty, "initialization is lazy")
        // Match AppDelegate.toggleTerminal: init → assign cwd → addSubview → ensureSession.
        // A collapsed split-view host can supply a zero frame when the panel is created.
        panel.workingDirectory = openedFile.deletingLastPathComponent()
        host.addSubview(panel)
        panel.frame = host.bounds
        panel.layoutSubtreeIfNeeded()
        pumpEvents(for: 0.05)
        try check(!panel.hasRunningSessions && terminals(in: panel).isEmpty,
                  "attaching and laying out the panel does not start a shell")
        panel.ensureSession()
        let first = try require(terminals(in: panel).first, "first terminal view was not created")
        let firstPID = first.process.shellPid
        try check(first.process.running && firstPID > 1, "zsh owns a live PTY")
        try wait("isolated zsh startup completed") { text(in: first).contains("orkhon-test> ") }
        first.send(txt: "printf '\\nCHECK_CWD=%s\\nCHECK_TERM=%s\\nCHECK_TTY=%s\\nCHECK_APP=%s\\n' \"$PWD\" \"$TERM\" \"$(tty)\" \"$TERM_PROGRAM\"\r")
        // The long scratch directory may wrap across terminal columns.
        try wait("cwd with quotes and shell metacharacters is passed literally") {
            text(in: first).replacingOccurrences(of: "\n", with: "").contains("CHECK_CWD=\(cwd.path)")
        }
        try checkPhysicalDirectory(cwd, in: first, marker: "FIRST_PHYSICAL_CWD",
                                   label: "parent creation sequence uses the opened file's physical directory")
        try wait("real TTY and xterm-256color environment") {
            text(in: first).contains("CHECK_TERM=xterm-256color") && text(in: first).contains("CHECK_TTY=/dev/")
        }
        try wait("terminal identifies the app as Orkhon Code") {
            text(in: first).contains("CHECK_APP=Orkhon Code")
        }
        panel.ensureSession()
        try check(terminals(in: panel).count == 1, "ensureSession does not duplicate a live tab")

        let oldColumns = first.getTerminal().cols
        panel.setFrameSize(NSSize(width: 580, height: 260))
        panel.layoutSubtreeIfNeeded()
        var size = winsize()
        let resizeResult = ioctl(first.process.childfd, TIOCGWINSZ, &size)
        try check(resizeResult == 0 && first.getTerminal().cols < oldColumns &&
                  Int(size.ws_col) == first.getTerminal().cols && Int(size.ws_row) == first.getTerminal().rows,
                  "resizing reaches the PTY rows and columns")
        panel.applyTheme(background: .black, foreground: .white, accent: .systemGreen)
        try check(first.nativeBackgroundColor == .black && first.nativeForegroundColor == .white &&
                  first.caretColor == .systemGreen, "theme updates native background, text, and cursor")

        first.send(txt: "sleep 60\r")
        try wait("foreground job started") {
            let group = tcgetpgrp(first.process.childfd)
            return group > 1 && group != firstPID
        }
        let interrupt = try require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        ), "could not construct the native Control-C event")
        first.keyDown(with: interrupt)
        try wait("native Control-C returns foreground control to zsh") {
            tcgetpgrp(first.process.childfd) == firstPID
        }
        first.send(txt: "printf '\\nCHECK_%s\\n' INTERRUPTED\r")
        try wait("shell accepts input after Control-C") { text(in: first).contains("CHECK_INTERRUPTED") }

        let nextDirectory = scratch.appendingPathComponent("next workspace", isDirectory: true)
        try manager.createDirectory(at: nextDirectory, withIntermediateDirectories: true)
        panel.workingDirectory = nextDirectory
        panel.ensureSession()
        try check(terminals(in: panel).count == 1 && first.process.shellPid == firstPID,
                  "changing cwd and reopening preserves the existing shell")
        try checkPhysicalDirectory(cwd, in: first, marker: "EXISTING_PHYSICAL_CWD",
                                   label: "changing the default cwd does not move an active shell")

        let plus = try require(descendants(of: panel).compactMap { $0 as? NSButton }.first {
            $0.toolTip?.hasPrefix("New Terminal (") == true
        }, "new-terminal button was not found")
        plus.performClick(nil)
        try check(terminals(in: panel).count == 2, "new button creates a second terminal tab")
        let second = try require(terminals(in: panel).first { $0 !== first }, "second terminal was not found")
        let secondPID = second.process.shellPid
        try check(secondPID > 1 && secondPID != firstPID && first.isHidden && !second.isHidden,
                  "tabs preserve independent processes and selection")
        try wait("second shell is ready") { text(in: second).contains("orkhon-test> ") }
        try checkPhysicalDirectory(nextDirectory, in: second, marker: "NEXT_PHYSICAL_CWD",
                                   label: "a new tab uses the updated physical working directory")
        second.send(txt: "sleep 60 &\r")
        try wait("background job started") { child(inSession: secondPID) != nil }
        let backgroundPID = try require(child(inSession: secondPID), "background job disappeared unexpectedly")
        let close = try require(descendants(of: panel).compactMap { $0 as? NSButton }.first {
            $0.toolTip == "Close terminal 2"
        }, "second terminal's close button was not found")
        close.performClick(nil)
        try check(terminals(in: panel).count == 1 && !first.isHidden, "closing a tab selects its neighbor")
        try wait("closing a tab cleans up its shell and background job") {
            isGone(secondPID) && isGone(backgroundPID)
        }

        // More than SwiftTerm's 128 KiB PTY read size. Checking a distinct final marker
        // catches closing DispatchIO before all reads are delivered after shell exit.
        first.send(txt: "for i in {1..30000}; do print -r -- $i; done; printf '\\nFINAL_%s\\n' OUTPUT; exit 7\r")
        try wait("natural exit updates running-session state", timeout: 15) { !panel.hasRunningSessions }
        try check(terminals(in: panel).count == 1, "exited tab preserves its scrollback")
        try wait("30,000-line final output survives natural exit") { text(in: first).contains("FINAL_OUTPUT") }
        try wait("raw wait status is normalized to exit code 7") {
            descendants(of: panel).compactMap(\.toolTip).joined().contains("Exited with status 7")
        }
        panel.ensureSession()
        try check(terminals(in: panel).count == 2 && panel.hasRunningSessions, "ensureSession replaces an exited shell")
        let final = try require(terminals(in: panel).last, "replacement terminal was not found")
        let finalPID = final.process.shellPid
        panel.terminateAll()
        panel.terminateAll()
        try wait("shutdown is idempotent and reaps the shell") {
            !panel.hasRunningSessions && terminals(in: panel).isEmpty && isGone(finalPID)
        }
    }
}
