import AppKit
import Darwin
@preconcurrency import SwiftTerm

/// A lazy, tabbed host for SwiftTerm 1.10.1's native AppKit/PTY implementation.
/// The owning split view controls visibility and expansion. All entry points are main-actor APIs.
@MainActor
final class TerminalPanel: NSView, @preconcurrency LocalProcessTerminalViewDelegate {
    /// The initial directory for future tabs. Existing shells are never sent an unsolicited `cd`.
    /// With no explicit directory, a new tab inherits the selected tab's last OSC 7 directory.
    var workingDirectory: URL?
    var remoteWorkspace:RemoteWorkspace?
    func startRemoteSession(_ workspace:RemoteWorkspace) {remoteWorkspace=workspace;if let existing=sessions.first(where:{$0.remoteID==workspace.controlPath && !$0.didExit}) {select(existing)} else {createSession()}}
    func endRemoteSessions() {for session in sessions.filter({$0.remoteID != nil}) {close(session)};remoteWorkspace=nil}

    var hasRunningSessions: Bool {
        sessions.contains { $0.terminal.process.running && !$0.didExit }
    }

    private let header = NSView()
    private let tabScroll = TabScrollView()
    private let tabDocument = NSView()
    private let content = NSView()
    private let newButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "Open a terminal to start a shell")
    private let emptyButton = NSButton(title: "New Terminal", target: nil, action: nil)
    private var sessions: [Session] = []
    private var retiringSessions: [Session] = []
    private var selectedID: Int?
    private var nextID = 1
    private var shuttingDown = false
    private var backgroundColor = NSColor.textBackgroundColor
    private var foregroundColor = NSColor.textColor
    private var accentColor = NSColor.controlAccentColor
    private let headerHeight: CGFloat = 38

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureInterface()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInterface()
    }

    deinit {
        // AppKit view teardown need not occur inside a Swift concurrency task.
        // Retain the sessions until their main-actor cleanup can run.
        let remaining = sessions + retiringSessions
        NotificationCenter.default.removeObserver(self)
        Task { @MainActor in
            for session in remaining { session.stop(immediately: true) }
        }
    }

    private func configureInterface() {
        wantsLayer = true
        header.wantsLayer = true
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        addSubview(header)
        addSubview(content)
        header.addSubview(tabScroll)
        header.addSubview(newButton)
        tabScroll.documentView = tabDocument
        tabScroll.drawsBackground = false
        tabScroll.borderType = .noBorder
        tabScroll.hasHorizontalScroller = false
        tabScroll.hasVerticalScroller = false
        tabScroll.autohidesScrollers = true
        tabScroll.scrollerStyle = .overlay
        configureIconButton(newButton, symbol: "plus", label: "New terminal")
        newButton.target = self
        newButton.action = #selector(newTerminal(_:))
        newButton.toolTip = "New Terminal (⌘T while the terminal is focused)"
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.alignment = .center
        emptyButton.bezelStyle = .rounded
        emptyButton.target = self
        emptyButton.action = #selector(newTerminal(_:))
        content.addSubview(emptyLabel)
        content.addSubview(emptyButton)
        setAccessibilityLabel("Terminal panel")
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification, object: nil
        )
        applyTheme(background: backgroundColor, foreground: foregroundColor, accent: accentColor)
    }

    /// Creates the first live session on demand, or restores focus to an existing live session.
    func ensureSession() {
        guard !shuttingDown else { return }
        if let selected = selectedSession, !selected.didExit, selected.terminal.process.running {
            focus(selected)
        } else if let running = sessions.first(where: { !$0.didExit && $0.terminal.process.running }) {
            select(running)
        } else {
            createSession()
        }
    }

    /// Idempotent shutdown; the parent may call this before NSApplication terminates.
    func terminateAll() {
        shuttingDown = true
        for session in sessions + retiringSessions {
            session.terminal.processDelegate = nil
            session.stop(immediately: true)
            session.terminal.removeFromSuperview()
            session.tab.removeFromSuperview()
        }
        sessions.removeAll()
        retiringSessions.removeAll()
        selectedID = nil
        newButton.isEnabled = false
        emptyButton.isEnabled = false
        needsLayout = true
    }

    func applyTheme(background: NSColor, foreground: NSColor, accent: NSColor) {
        backgroundColor = background
        foregroundColor = foreground
        accentColor = accent
        tabScroll.accent=accent
        updateTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTheme()
    }

    private func updateTheme() {
        // Resolve dynamic NSColors in this view's appearance, including when it is hidden.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = backgroundColor.cgColor
            content.layer?.backgroundColor = backgroundColor.cgColor
            header.layer?.backgroundColor = backgroundColor.blended(
                withFraction: 0.04, of: foregroundColor
            )?.cgColor ?? backgroundColor.cgColor
            newButton.contentTintColor = foregroundColor
            emptyLabel.textColor = foregroundColor.withAlphaComponent(0.65)
            for session in sessions {
                let terminal = session.terminal
                terminal.nativeBackgroundColor = backgroundColor
                terminal.nativeForegroundColor = foregroundColor
                terminal.caretColor = accentColor
                terminal.caretTextColor = backgroundColor
                terminal.selectedTextBackgroundColor = accentColor.withAlphaComponent(0.30)
                terminal.needsDisplay = true
                updateTab(session)
            }
        }
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width)
        let barHeight = min(headerHeight, max(0, bounds.height))
        header.frame = NSRect(x: 0, y: 0, width: width, height: barHeight)
        newButton.frame = NSRect(x: max(0, width - 34), y: 5, width: 28, height: 28)
        tabScroll.frame = NSRect(x: 8, y: 3, width: max(0, width - 48), height: 35)
        content.frame = NSRect(x: 0, y: barHeight, width: width,
                               height: max(0, bounds.height - barHeight))
        var x: CGFloat = 0
        for session in sessions {
            let tabWidth = min(220, max(136, session.button.intrinsicContentSize.width + 40))
            session.tab.frame = NSRect(x: x, y: 2, width: tabWidth, height: 28)
            session.button.frame = NSRect(x: 8, y: 2, width: tabWidth - 38, height: 24)
            session.closeButton.frame = NSRect(x: tabWidth - 27, y: 3, width: 22, height: 22)
            x += tabWidth + 4
        }
        tabDocument.frame = NSRect(x: 0, y: 0, width: max(x, tabScroll.contentSize.width), height: 32)
        // Avoid shrinking a collapsed terminal to zero rows/columns. setFrameSize is
        // SwiftTerm's own resize path, including TIOCSWINSZ and SIGWINCH for the PTY.
        if content.bounds.width >= 40, content.bounds.height >= 30 {
            for session in sessions {
                session.terminal.frame = content.bounds
            }
        }
        emptyLabel.isHidden = !sessions.isEmpty
        emptyButton.isHidden = !sessions.isEmpty
        emptyLabel.frame = NSRect(x: 12, y: max(4, content.bounds.midY + 8),
                                 width: max(0, width - 24), height: 20)
        emptyButton.frame = NSRect(x: max(0, (width - 124) / 2),
                                  y: max(0, content.bounds.midY - 28), width: 124, height: 28)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let session = selectedSession { focus(session) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Do not claim the editor's or window's shortcuts when focus is elsewhere.
        guard let responder = window?.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "t" {
            createSession()
            return true
        }
        if flags == .command, key == "w", let selected = selectedSession {
            close(selected)
            return true
        }
        if flags == [.command, .shift], key == "[" || key == "]" || key == "{" || key == "}" {
            switchTab(by: key == "[" || key == "{" ? -1 : 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private var selectedSession: Session? { sessions.first { $0.id == selectedID } }

    @objc private func newTerminal(_ sender: Any?) { createSession() }

    private func createSession() {
        guard !shuttingDown else { return }
        layoutSubtreeIfNeeded()
        let requestedDirectory = workingDirectory ?? selectedSession?.directory
        let directory = validDirectory(requestedDirectory) ?? FileManager.default.homeDirectoryForCurrentUser
        let size = content.bounds.width >= 40 && content.bounds.height >= 30
            ? content.bounds.size : NSSize(width: 720, height: 320)
        let terminal = LocalProcessTerminalView(frame: NSRect(origin: .zero, size: size))
        terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.processDelegate = self
        terminal.setAccessibilityLabel("Terminal \(nextID)")
        // Preserve SwiftTerm's terminalDelegate: it connects key input and resize events to the PTY.
        let session = Session(id: nextID, terminal: terminal, directory: directory)
        session.remoteID=remoteWorkspace?.controlPath;session.remoteHost=remoteWorkspace?.host
        nextID += 1
        session.tab.wantsLayer = true
        session.tab.layer?.cornerRadius = 5
        session.button.isBordered = false
        session.button.alignment = .left
        session.button.font = .systemFont(ofSize: 11, weight: .medium)
        session.button.cell?.lineBreakMode = .byTruncatingTail
        session.button.target = self
        session.button.action = #selector(selectTab(_:))
        session.button.tag = session.id
        configureIconButton(session.closeButton, symbol: "xmark", label: "Close terminal \(session.id)")
        session.closeButton.target = self
        session.closeButton.action = #selector(closeTab(_:))
        session.closeButton.tag = session.id
        session.tab.addSubview(session.button)
        session.tab.addSubview(session.closeButton)
        tabDocument.addSubview(session.tab)
        content.addSubview(terminal)
        sessions.append(session)
        select(session)
        updateTheme()
        terminal.startProcess(executable: remoteWorkspace == nil ? "/bin/zsh":"/usr/bin/ssh", args: remoteWorkspace?.terminalArguments ?? ["-l", "-i"],
                              environment: shellEnvironment(directory: directory),
                              execName: remoteWorkspace == nil ? "zsh":"ssh", currentDirectory: directory.path)
        session.processDidStart()
        if !terminal.process.running {
            session.didExit = true
            session.exitDescription = "Could not start zsh"
            terminal.feed(text: "\r\nUnable to start /bin/zsh. Close this tab and try a new terminal.\r\n")
        }
        updateTab(session)
        needsLayout = true
    }

    private func shellEnvironment(directory: URL) -> [String] {
        // SwiftTerm's default environment deliberately drops PATH and most inherited values.
        // Preserve the app's environment so developer tools and SSH_AUTH_SOCK remain available.
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Orkhon Editor"
        environment["SHELL"] = "/bin/zsh"
        environment["PWD"] = directory.path
        environment["HOME"] = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if environment["LANG"]?.isEmpty != false { environment["LANG"] = "en_US.UTF-8" }
        // Stale dimensions inherited from the launching terminal override the actual PTY size in tools.
        environment.removeValue(forKey: "COLUMNS")
        environment.removeValue(forKey: "LINES")
        return environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
    }

    private func validDirectory(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue, access(url.path, X_OK) == 0 else { return nil }
        return url.standardizedFileURL
    }

    @objc private func selectTab(_ sender: NSButton) {
        if let session = sessions.first(where: { $0.id == sender.tag }) { select(session) }
    }

    @objc private func closeTab(_ sender: NSButton) {
        if let session = sessions.first(where: { $0.id == sender.tag }) { close(session) }
    }

    private func select(_ session: Session) {
        selectedID = session.id
        for item in sessions {
            item.terminal.isHidden = item !== session
            updateTab(item)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        session.tab.scrollToVisible(session.tab.bounds)
        focus(session)
    }

    private func focus(_ session: Session) {
        guard !isHiddenOrHasHiddenAncestor, let window else { return }
        window.makeFirstResponder(session.terminal)
    }

    private func switchTab(by offset: Int) {
        guard !sessions.isEmpty, let index = sessions.firstIndex(where: { $0.id == selectedID }) else { return }
        select(sessions[(index + offset + sessions.count) % sessions.count])
    }

    private func close(_ session: Session) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        let wasSelected = selectedID == session.id
        session.terminal.processDelegate = nil
        session.stop(immediately: false)
        retiringSessions.append(session)
        // Keep the view/process alive while SwiftTerm drains DispatchIO and reaps its child.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, session] in
            session.finishStopping()
            self?.retiringSessions.removeAll { $0 === session }
        }
        session.terminal.removeFromSuperview()
        session.tab.removeFromSuperview()
        sessions.remove(at: index)
        if wasSelected {
            selectedID = nil
            if !sessions.isEmpty { select(sessions[min(index, sessions.count - 1)]) }
            else { window?.makeFirstResponder(emptyButton) }
        }
        needsLayout = true
    }

    private func updateTab(_ session: Session) {
        let selected = session.id == selectedID
        let label = session.title.isEmpty ? "zsh · \(session.id)" : session.title
        session.button.title = (session.remoteHost.map{"SSH "+$0+" · "} ?? "") + (session.didExit ? "\(label) — exited" : label)
        session.button.contentTintColor = selected ? accentColor : foregroundColor.withAlphaComponent(0.75)
        session.closeButton.contentTintColor = foregroundColor.withAlphaComponent(0.6)
        session.tab.layer?.backgroundColor = accentColor.withAlphaComponent(selected ? 0.19:0.045).cgColor
        session.tab.layer?.borderWidth=1
        session.tab.layer?.borderColor=accentColor.withAlphaComponent(selected ? 0.8:0.23).cgColor
        session.button.setAccessibilityLabel("\(session.button.title)\(selected ? ", selected" : "")")
        session.tab.toolTip = [session.directory.path, session.exitDescription].compactMap { $0 }.joined(separator: "\n")
    }

    private func configureIconButton(_ button: NSButton, symbol: String, label: String) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .inline
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    @objc private func applicationWillTerminate(_ notification: Notification) { terminateAll() }

    // SwiftTerm 1.10.1 creates its LocalProcess with the main dispatch queue.
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // The LocalProcessTerminalView already applied the PTY's new size before this callback.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let session = sessions.first(where: { $0.terminal === source }) else { return }
        session.title = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined().prefix(100))
        updateTab(session)
        needsLayout = true
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let session = sessions.first(where: { $0.terminal === source }), let directory else { return }
        let url: URL?
        if directory.hasPrefix("/") { url = URL(fileURLWithPath: directory, isDirectory: true) }
        else if let candidate = URL(string: directory), candidate.isFileURL,
                candidate.host == nil || candidate.host == "" || candidate.host == "localhost" ||
                candidate.host?.lowercased() == ProcessInfo.processInfo.hostName.lowercased() {
            url = candidate
        } else { url = nil }
        if let valid = validDirectory(url) {
            session.directory = valid
            updateTab(session)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let session = sessions.first(where: { $0.terminal === source }), !session.didExit else { return }
        session.didExit = true
        // v1.10.1 passes waitpid's raw status, not a normalized shell exit code.
        if let status = exitCode {
            let signal = status & 0x7f
            session.exitDescription = signal == 0 ? "Exited with status \((status >> 8) & 0xff)" : "Ended by signal \(signal)"
        } else {
            session.exitDescription = "Session ended"
        }
        session.drainAfterExit()
        // Keep all output available for selection/copy; never replace an exited tab implicitly.
        updateTab(session)
        needsLayout = true
    }
}

@MainActor
private final class Session {
    let id: Int
    let terminal: LocalProcessTerminalView
    let tab = NSView()
    let button = NSButton()
    let closeButton = NSButton()
    var title = ""
    var remoteID:String?,remoteHost:String?
    var directory: URL
    var didExit = false
    var exitDescription: String?
    private var didStop = false
    private var shellIdentity: TerminalProcessIdentity?
    private var stoppedProcesses: [TerminalProcessIdentity] = []

    init(id: Int, terminal: LocalProcessTerminalView, directory: URL) {
        self.id = id
        self.terminal = terminal
        self.directory = directory
    }

    func processDidStart() {
        shellIdentity = TerminalProcessIdentity(pid: terminal.process.shellPid)
    }

    func drainAfterExit(until deadline: Date = Date().addingTimeInterval(5)) {
        guard !didStop else { return }
        // In 1.10.1 waitpid/exit delivery can precede the final DispatchIO reads.
        // EOF sets childfd to -1. Closing earlier loses the tail of large output.
        if terminal.process.childfd < 0 || Date() >= deadline {
            stop(immediately: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in finishStopping() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                drainAfterExit(until: deadline)
            }
        }
    }

    func stop(immediately: Bool) {
        if !didStop {
            didStop = true
            let pid = terminal.process.shellPid
            // terminate() in this pinned release also signals its saved shellPid.
            // Do not call it if that PID has already been reassigned after a natural exit.
            if let current = TerminalProcessIdentity(pid: pid), current != shellIdentity { return }
            // forkpty establishes a new session. Include foreground and background job groups,
            // but never touch an unrelated process or a daemon that deliberately detached.
            stoppedProcesses = TerminalProcessIdentity.members(ofSession: pid)
            for process in stoppedProcesses {
                process.signal(SIGHUP)
                process.signal(SIGCONT)
            }
            // Only SwiftTerm may close the PTY descriptor; closing it manually races DispatchIO.
            terminal.terminate()
        }
        if immediately { finishStopping() }
    }

    func finishStopping() {
        for process in stoppedProcesses { process.signal(SIGKILL) }
        stoppedProcesses.removeAll()
    }
}

/// PID plus birth time prevents a delayed escalation from signalling a recycled PID.
private struct TerminalProcessIdentity: Sendable, Equatable {
    let pid: pid_t
    let seconds: UInt64
    let microseconds: UInt64

    init?(pid: pid_t) {
        guard pid > 1, pid != getpid() else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        self.pid = pid
        seconds = info.pbi_start_tvsec
        microseconds = info.pbi_start_tvusec
    }

    func signal(_ value: Int32) {
        guard let current = TerminalProcessIdentity(pid: pid),
              current.seconds == seconds, current.microseconds == microseconds else { return }
        _ = Darwin.kill(pid, value)
    }

    static func members(ofSession sessionID: pid_t) -> [TerminalProcessIdentity] {
        guard sessionID > 1, sessionID != getsid(0) else { return [] }
        let capacity = max(64, Int(proc_listallpids(nil, 0)) + 64)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        return pids.prefix(max(0, min(Int(count), capacity))).compactMap { pid in
            guard pid > 1, getsid(pid) == sessionID else { return nil }
            return TerminalProcessIdentity(pid: pid)
        }
    }
}
