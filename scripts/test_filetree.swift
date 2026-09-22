// Run with scripts/test_filetree.sh on macOS in a logged-in GUI session.
// The runner appends this harness to the unmodified production source, so private
// filesystem and model types can be tested without exposing test APIs in the app.
// All ordinary filesystem fixtures live in one disposable temporary directory.
// --trash additionally trashes and restores two uniquely named test fixtures.
import AppKit
import Darwin

private extension FileTreePanel {
    func testSuspendReads(_ value:Bool) {reads.isSuspended=value}
    var testOperationInProgress: Bool { operationInProgress }
    func testPerform(_ operation: FileTreeDisk.Operation, target: FileTreeTarget, name: String) {
        perform(operation, target: target, name: name)
    }
    func testSuspendMutations() { mutations.suspend() }
    func testResumeMutations() { mutations.resume() }
}

@MainActor private final class CheckWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@main
private struct FileTreeChecks {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("LumenFileTree-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Workspace", isDirectory: true)
        let other = fixture.appendingPathComponent("Other", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        try fm.createDirectory(at: other, withIntermediateDirectories: false)
        try Data("outside".utf8).write(to: other.appendingPathComponent("outside.txt"))
        for folder in ["Alpha", "Beta", ".git", ".build", "build", "node_modules"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        try fm.createDirectory(at: root.appendingPathComponent("Alpha/Nested"), withIntermediateDirectories: false)
        for file in ["file2.txt", "file10.txt", ".hidden", "Alpha/Nested/deep.txt", "Beta/child.txt"] {
            try Data("keep me".utf8).write(to: root.appendingPathComponent(file))
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("LinkFolder"), withDestinationURL: other)
        try fm.createSymbolicLink(at: root.appendingPathComponent("LinkFile"), withDestinationURL: other.appendingPathComponent("outside.txt"))
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            if !condition() { fatalError(message) }
        }
        func fails(_ label: String, _ body: () throws -> Void) {
            do { try body(); fatalError("Expected failure: " + label) }
            catch { assertions += 1 }
        }
        func listing(_ hidden: Bool = false) throws -> FileTreeDisk.Listing {
            try FileTreeDisk.read(root, root: root, rootIdentity: nil, expectedIdentity: nil, includeHidden: hidden)
        }
        let initial = try listing()
        check(initial.entries.map { $0.url.lastPathComponent } == ["Alpha", "Beta", "file2.txt", "file10.txt", "LinkFile", "LinkFolder"], "natural folder-first ordering / filters")
        let hiddenCount = tryCount(try listing(true))
        check(hiddenCount == 11, "hidden toggle includes exclusions")
        let link = initial.entries.first { $0.url.lastPathComponent == "LinkFolder" }!
        check(link.kind == .link, "symlink must be a leaf")
        fails("no traversal of symlink") {
            _ = try FileTreeDisk.read(link.url, root: root, rootIdentity: initial.identity, expectedIdentity: link.identity, includeHidden: true)
        }
        fails("no traversal outside root") {
            _ = try FileTreeDisk.read(other, root: root, rootIdentity: initial.identity, expectedIdentity: nil, includeHidden: true)
        }
        fails("read cancellation") {
            _ = try FileTreeDisk.read(root, root: root, rootIdentity: initial.identity, expectedIdentity: nil, includeHidden: true, isCancelled: { true })
        }
        let rootTarget = FileTreeTarget(url: root, root: root, identity: initial.identity, rootIdentity: initial.identity, generation: UUID())
        _ = try FileTreeDisk.perform(.newFile, target: rootTarget, name: "Created.txt")
        let created = root.appendingPathComponent("Created.txt")
        try Data("must survive".utf8).write(to: created)
        fails("create cannot overwrite") { _ = try FileTreeDisk.perform(.newFile, target: rootTarget, name: "Created.txt") }
        let originalContents = try String(contentsOf: created, encoding: .utf8)
        check(originalContents == "must survive", "existing bytes preserved")
        _ = try FileTreeDisk.perform(.newFolder, target: rootTarget, name: "CreatedFolder")
        fails("mkdir collision") { _ = try FileTreeDisk.perform(.newFolder, target: rootTarget, name: "CreatedFolder") }
        for bad in ["", " ", ".", "..", "../escape", "a/b", "a:b", "a\0b"] {
            check(!FileTreeDisk.validName(bad), "invalid name: " + bad)
        }
        func target(_ name: String) throws -> FileTreeTarget {
            let list = try listing(true)
            let entry = list.entries.first { $0.url.lastPathComponent == name }!
            return FileTreeTarget(url: entry.url, root: root, identity: entry.identity, rootIdentity: list.identity, generation: UUID())
        }
        let createdTarget = try target("Created.txt")
        fails("rename cannot overwrite") { _ = try FileTreeDisk.perform(.rename, target: createdTarget, name: "file2.txt") }
        _ = try FileTreeDisk.perform(.rename, target: createdTarget, name: "Renamed.txt")
        check(fm.fileExists(atPath: root.appendingPathComponent("Renamed.txt").path), "rename succeeds")
        let caseTarget = try target("Renamed.txt")
        _ = try FileTreeDisk.perform(.rename, target: caseTarget, name: "renamed.txt")
        check((try? listing(true).entries.contains { $0.url.lastPathComponent == "renamed.txt" }) == true, "case-only rename succeeds")
        let stale = try target("file2.txt")
        try fm.moveItem(at: stale.url, to: root.appendingPathComponent("moved-original.txt"))
        try Data("replacement".utf8).write(to: stale.url)
        fails("changed identity blocks rename") { _ = try FileTreeDisk.perform(.rename, target: stale, name: "bad.txt") }
        fails("changed identity blocks trash") { _ = try FileTreeDisk.perform(.trash, target: stale, name: "") }
        fails("root cannot be trashed") { _ = try FileTreeDisk.perform(.trash, target: rootTarget, name: "") }
        fails("link cannot be opened") { try FileTreeDisk.checkFile(target("LinkFile")) }
        let beta = try target("Beta")
        try fm.moveItem(at: beta.url, to: root.appendingPathComponent("OriginalBeta"))
        try fm.createSymbolicLink(at: beta.url, withDestinationURL: other)
        fails("replaced folder cannot be read") {
            _ = try FileTreeDisk.read(beta.url, root: root, rootIdentity: beta.rootIdentity, expectedIdentity: beta.identity, includeHidden: true)
        }
        fails("replaced folder cannot receive a new file") { _ = try FileTreeDisk.perform(.newFile, target: beta, name: "escape.txt") }
        check(!fm.fileExists(atPath: other.appendingPathComponent("escape.txt").path), "no writes through symlinks")
        print("Filesystem checks passed (\(assertions) assertions)")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let panel = FileTreePanel(frame: NSRect(x: 0, y: 0, width: 280, height: 560))
        var moves: [(URL, URL)] = []
        var trashed: [URL] = []
        panel.onMove = { old, new in
            check(Thread.isMainThread, "move callback runs on main thread")
            check(fm.fileExists(atPath: new.path), "move callback runs after filesystem success")
            moves.append((old, new))
        }
        panel.onTrash = { original in
            check(Thread.isMainThread, "trash callback runs on main thread")
            check(!fm.fileExists(atPath: original.path), "trash callback runs after filesystem success")
            trashed.append(original)
        }
        func descendant<T: NSView>(_ view: NSView, _ type: T.Type) -> T? {
            if let found = view as? T { return found }
            for child in view.subviews { if let found = descendant(child, type) { return found } }
            return nil
        }
        let outline = descendant(panel, FileTreeOutlineView.self)!
        func wait(_ message: String, until predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !predicate(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            check(predicate(), message)
        }
        func rows() -> [FileTreeNode] {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FileTreeNode }
        }
        func node(_ name: String) -> FileTreeNode? { rows().first { $0.name == name } }
        panel.setRoot(root)
        wait("workspace loads") { node("Alpha") != nil }
        check(node("Alpha")!.state == .unloaded, "collapsed folder must stay unread")
        check(node("OriginalBeta")!.state == .unloaded, "unrelated collapsed folder unread")
        outline.expandItem(node("Alpha")!)
        wait("expansion reads children") { node("Nested") != nil }
        outline.expandItem(node("Nested")!)
        wait("nested expansion reads children") { node("deep.txt") != nil }
        // A refresh must retain the children that NSOutlineView still references.
        let priorRows=rows().map(\.name)
        panel.testSuspendReads(true)
        panel.setOpenFiles([root.appendingPathComponent("Alpha/Nested/deep.txt")],activeURL:nil,workspaceMode:false)
        check(rows().map(\.name)==priorRows,"opening a tab preserves published rows during async refresh")
        for i in 0..<25 {panel.setOpenFiles([root.appendingPathComponent(i.isMultiple(of:2) ? "file10.txt":"Alpha/Nested/deep.txt")],activeURL:nil,workspaceMode:false);_ = rows()}
        panel.testSuspendReads(false)
        wait("open-file refresh preserves nested rows") {node("deep.txt") != nil}
        let deep = node("deep.txt")!
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: deep)), byExtendingSelection: false)
        panel.refresh()
        wait("refresh restores deep selection") {
            (outline.item(atRow: outline.selectedRow) as? FileTreeNode)?.name == "deep.txt"
        }
        check(node("OriginalBeta")!.state == .unloaded, "refresh does not traverse collapsed folders")
        panel.applyTheme(background: .black, foreground: .white, accent: .systemOrange)
        check(node("deep.txt") != nil, "theme preserves expansion")
        var opened: URL?
        panel.onOpenFile = { opened = $0 }
        outline.openSelection?()
        wait("open callback receives selected file") { opened == deep.url }
        let menu = outline.makeContextMenu?(outline.row(forItem: node("deep.txt")!))
        check(menu?.items.map(\.title) == ["New File…", "New Folder…", "", "Rename…", "Move to Trash…", "", "Reveal in Finder", "Refresh"], "context menu actions")
        let betaNode = node("OriginalBeta")!
        outline.expandItem(betaNode)
        outline.collapseItem(betaNode)
        wait("collapsed in-flight folder finishes") { betaNode.state == .loaded }
        check(!outline.isItemExpanded(betaNode), "load completion must not reopen collapsed folder")
        for i in 0..<40 { panel.setRoot(i.isMultiple(of: 2) ? root : other) }
        wait("latest workspace wins") { rows().contains { $0.name == "outside.txt" } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(rows().map(\.name) == ["outside.txt"], "stale workspace results discarded")
        panel.setRoot(root)
        wait("workspace reloads") { node("Alpha") != nil }
        _ = panel.perform(NSSelectorFromString("toggleHidden"))
        wait("hidden files appear") { node(".git") != nil }
        _ = panel.perform(NSSelectorFromString("toggleHidden"))
        wait("hidden files disappear") { node("Alpha") != nil && node(".git") == nil }

        let window = CheckWindow(contentRect: NSRect(x: -10000, y: -10000, width: 280, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = window.contentView!
        panel.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            panel.topAnchor.constraint(equalTo: host.topAnchor),
            panel.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        window.alphaValue = 0 // Real native sheets without a visible test window.
        window.orderFront(nil)
        window.setContentSize(NSSize(width: 280, height: 560))
        panel.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(outline.bounds.width > 200, "outline resizes with panel")
        check(outline.visibleRect.height > 400, "outline fills available height")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let rootMenu = outline.makeContextMenu?(-1)!
        let createItem = rootMenu!.items.first { $0.title == "New File…" }!
        check(NSApp.sendAction(createItem.action!, to: createItem.target, from: createItem), "create menu action dispatched")
        wait("name sheet presented") { window.attachedSheet != nil }
        let createSheet = window.attachedSheet!
        let nameField = descendants(createSheet.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        nameField.stringValue = "FromDialog.txt"
        window.endSheet(createSheet, returnCode: .alertFirstButtonReturn)
        wait("name dialog creates and selects file") {
            (outline.item(atRow: outline.selectedRow) as? FileTreeNode)?.name == "FromDialog.txt"
        }
        let newNode = node("FromDialog.txt")!
        let fileMenu = outline.makeContextMenu?(outline.row(forItem: newNode))!
        let trashItem = fileMenu!.items.first { $0.title == "Move to Trash…" }!
        check(NSApp.sendAction(trashItem.action!, to: trashItem.target, from: trashItem), "trash menu action dispatched")
        wait("trash confirmation presented") { window.attachedSheet != nil }
        let trashSheet = window.attachedSheet!
        check(trashSheet.defaultButtonCell?.title == "Cancel", "trash confirmation defaults to Cancel")
        window.endSheet(trashSheet, returnCode: .alertFirstButtonReturn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(fm.fileExists(atPath: root.appendingPathComponent("FromDialog.txt").path), "cancel leaves file untouched")
        outline.expandItem(node("Alpha")!)
        wait("preview expanded") { node("Nested") != nil }
        panel.layoutSubtreeIfNeeded()
        panel.needsDisplay = true
        panel.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let labels = descendants(panel).compactMap { $0 as? NSTextField }.filter { !$0.stringValue.isEmpty }
        check(labels.allSatisfy { !$0.isHidden && $0.bounds.width > 0 && $0.bounds.height > 0 }, "visible text fields have nonempty layout")
        window.setContentSize(NSSize(width: 160, height: 560))
        panel.layoutSubtreeIfNeeded()
        check(outline.bounds.width <= 160, "narrow split view resizes outline")

        check(moves.isEmpty && trashed.isEmpty, "creation and cancelled Trash emit no mutation callbacks")

        // File rename, including exactly-once delivery and unchanged names.
        let fromDialog = try target("FromDialog.txt")
        panel.testPerform(.rename, target: fromDialog, name: "MovedDialog.txt")
        wait("file move callback") { moves.count == 1 }
        check(moves[0].0 == fromDialog.url && moves[0].1.path == root.appendingPathComponent("MovedDialog.txt").path,
              "move callback reports old and new file URLs")
        wait("moved file visible") { node("MovedDialog.txt") != nil }
        let unchangedMenu = outline.makeContextMenu?(outline.row(forItem: node("MovedDialog.txt")!))!
        let renameItem = unchangedMenu!.items.first { $0.title == "Rename…" }!
        check(NSApp.sendAction(renameItem.action!, to: renameItem.target, from: renameItem), "rename dialog dispatched")
        wait("rename dialog presented") { window.attachedSheet != nil }
        window.endSheet(window.attachedSheet!, returnCode: .alertFirstButtonReturn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(moves.count == 1 && !panel.testOperationInProgress, "unchanged name emits no move callback")

        // A directory reports its own URL pair once, not one notification per child.
        let alphaTarget = try target("Alpha")
        panel.testPerform(.rename, target: alphaTarget, name: "MovedAlpha")
        wait("directory move callback") { moves.count == 2 }
        check(moves[1].0 == alphaTarget.url && moves[1].1.hasDirectoryPath,
              "directory move callback preserves directory URL semantics")
        check(fm.fileExists(atPath: moves[1].1.appendingPathComponent("Nested/deep.txt").path),
              "directory callback points to relocated descendants")
        wait("directory selection and expansion restored") { node("Nested") != nil && node("MovedAlpha") != nil }

        // Failed disk operations report native errors, without notifying the host.
        panel.testPerform(.rename, target: try target("MovedDialog.txt"), name: "file10.txt")
        wait("failed rename presents alert") { !panel.testOperationInProgress && window.attachedSheet != nil }
        check(moves.count == 2, "failed rename emits no move callback")
        window.endSheet(window.attachedSheet!, returnCode: .alertFirstButtonReturn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let staleTrashURL = root.appendingPathComponent("StaleTrash.txt")
        try Data("original".utf8).write(to: staleTrashURL)
        let staleTrash = try target("StaleTrash.txt")
        try fm.moveItem(at: staleTrashURL, to: root.appendingPathComponent("StaleTrashOriginal.txt"))
        try Data("replacement".utf8).write(to: staleTrashURL)
        panel.testPerform(.trash, target: staleTrash, name: "")
        wait("failed trash presents alert") { !panel.testOperationInProgress && window.attachedSheet != nil }
        check(trashed.isEmpty, "failed Trash emits no callback")
        window.endSheet(window.attachedSheet!, returnCode: .alertFirstButtonReturn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // Suspend only the worker queue to deterministically switch workspaces in flight.
        panel.testSuspendMutations()
        panel.testPerform(.rename, target: try target("MovedDialog.txt"), name: "MovedWhileAway.txt")
        panel.setRoot(other)
        panel.testResumeMutations()
        wait("move callback survives workspace change") { moves.count == 3 }
        check(moves[2].1.path == root.appendingPathComponent("MovedWhileAway.txt").path && panel.rootURL == other,
              "old workspace mutation notifies without replacing the current workspace")
        wait("other workspace remains visible") { node("outside.txt") != nil }
        check(rows().map(\.name) == ["outside.txt"], "old mutation does not refresh the wrong workspace")

        // Actual Trash is opt-in. Restore only these UUID-named disposable fixtures;
        // never enumerate, empty, or delete the user's Trash.
        if CommandLine.arguments.contains("--trash") {
            let trashDirectory = try fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: root, create: true)
            for isFolder in [false, true] {
                let leaf = "LumenFileTree-" + UUID().uuidString + (isFolder ? "" : ".txt")
                let original = root.appendingPathComponent(leaf, isDirectory: isFolder)
                if isFolder {
                    try fm.createDirectory(at: original, withIntermediateDirectories: false)
                    try Data("disposable fixture".utf8).write(to: original.appendingPathComponent("child.txt"))
                } else {
                    try Data("disposable fixture".utf8).write(to: original)
                }
                let disposable = try target(leaf)
                let previousCount = trashed.count
                panel.testPerform(.trash, target: disposable, name: "")
                wait("successful Trash callback with a different workspace selected") { !panel.testOperationInProgress }
                check(trashed.count == previousCount + 1 && trashed.last == original,
                      "Trash callback reports the original file/directory URL exactly once")
                check(panel.rootURL == other, "Trash completion leaves the current workspace intact")
                let recovery = trashDirectory.appendingPathComponent(leaf, isDirectory: isFolder)
                var info = stat()
                check(lstat(recovery.path, &info) == 0 && FileTreeDisk.Identity(info) == disposable.identity,
                      "only the exact test fixture is restored from Trash")
                try fm.moveItem(at: recovery, to: original)
            }
        } else {
            print("Actual Trash success checks skipped; add --trash to exercise and restore disposable fixtures.")
        }
        panel.onMove = nil
        panel.onTrash = nil
        window.orderOut(nil)
        panel.rootURL = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(panel.rootURL == nil && rows().count == 1 && rows().first?.url == nil, "clearing root cancels and resets")
        print("All checks passed (\(assertions) assertions)")
    }
    private static func tryCount(_ listing: FileTreeDisk.Listing) -> Int { listing.entries.count }
}
