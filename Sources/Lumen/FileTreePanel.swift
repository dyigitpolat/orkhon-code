import AppKit
import Darwin
import UniformTypeIdentifiers

/// A self-contained, main-thread AppKit sidebar. Directory contents are read only
/// for the workspace and expanded folders; filesystem work never runs on the UI thread.
@MainActor
final class FileTreePanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenFileInNewWindow: ((URL) -> Void)?
    private var openPaths=Set<String>()
    private var activePath:String?
    private var revealedRoot:String?
    private var requiredPaths=Set<String>()
    var expandedOpenPaths:Set<String> {expandedPaths}
    var highlightedOpenPaths:Set<String> {openPaths}
    var isWorkspaceMode=false

    func setOpenFiles(_ urls:[URL],activeURL:URL?,workspaceMode:Bool) {
        let next=Set(urls.map{$0.standardizedFileURL.path})
        let changed=next != openPaths || revealedRoot != rootURL?.path
        openPaths=next;activePath=activeURL?.standardizedFileURL.path;isWorkspaceMode=workspaceMode
        titleLabel.toolTip=(workspaceMode ? "Workspace · ":"Open files · ")+(rootURL?.path ?? "")
        if changed,let rootURL {
            revealedRoot=rootURL.path;requiredPaths=[]
            for url in urls where url.path==rootURL.path || url.path.hasPrefix(rootURL.path == "/" ? "/":rootURL.path+"/") {
                requiredPaths.insert(url.path)
                var parent=url.deletingLastPathComponent()
                while parent.path != rootURL.path && parent.path != "/" {requiredPaths.insert(parent.path);expandedPaths.insert(parent.path);parent=parent.deletingLastPathComponent()}
            }
            if let root {
                if root.state == .loaded {root.state = .unloaded;load(root)}
                else {restoreState(below:root)}
            }
        }
        for row in 0..<outline.numberOfRows {
            if let node=outline.item(atRow:row) as? FileTreeNode,let cell=outline.view(atColumn:0,row:row,makeIfNecessary:false) as? NSTableCellView {style(cell,for:node)}
        }
    }

    var onOpenFile: ((URL) -> Void)?
    var onChooseFolder: (() -> Void)?
    /// Called on the main thread after a successful file or directory rename/move.
    /// Directory moves report the directory pair once; the host updates descendant tabs.
    var onMove: ((URL, URL) -> Void)?
    /// Called on the main thread after successful Trash, with the original item URL.
    /// The host should protect buffers for this item and, for a directory, its descendants.
    var onTrash: ((URL) -> Void)?

    var rootURL: URL? {
        get { root?.url }
        set {
            if let newValue { setRoot(newValue) }
            else { reset(to: nil, preservingState: false) }
        }
    }

    private let titleLabel = NSTextField(labelWithString: "Workspace")
    private let folderButton = NSButton()
    private let refreshButton = NSButton()
    private let hiddenButton = NSButton()
    private let scrollView = NSScrollView()
    private let outline = FileTreeOutlineView()
    private let separator = NSBox()
    private let reads: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Lumen.FileTree.Reads"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let mutations = DispatchQueue(label: "Lumen.FileTree.Mutations", qos: .userInitiated)

    private var root: FileTreeNode?
    private var nodes: [String: FileTreeNode] = [:]
    private let emptyNode = FileTreeNode(message: "Open a folder to get started")
    private var generation = UUID()
    private var expandedPaths = Set<String>()
    private var pendingSelection: String?
    private var reloading = false
    private var showsHiddenFiles = false
    private var operationInProgress = false
    private var reportedReadError = false
    private var foreground = NSColor.labelColor
    private var accent = NSColor.controlAccentColor
    private var iconCache: [String: NSImage] = [:]
    private var alerts: [(NSAlert, (NSApplication.ModalResponse) -> Void)] = []
    private var showingAlert = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureViews()
    }

    deinit { reads.cancelAllOperations() }

    func setRoot(_ url: URL) {
        guard url.isFileURL else {
            showError("Couldn’t Open Workspace", detail: "Choose a folder on the filesystem.")
            return
        }
        reset(to: url.standardizedFileURL, preservingState: false)
    }

    /// Explicit refresh also picks up changes made outside this panel. Expansion
    /// and selection are restored lazily, without walking collapsed directories.
    func refresh() {
        guard let url = rootURL else { return }
        reset(to: url, preservingState: true)
    }

    func applyTheme(background: NSColor, foreground: NSColor, accent: NSColor) {
        self.foreground = foreground
        self.accent = accent
        layer?.backgroundColor = background.cgColor
        scrollView.backgroundColor = background
        outline.backgroundColor = background
        titleLabel.textColor = foreground
        folderButton.contentTintColor = foreground
        refreshButton.contentTintColor = foreground
        hiddenButton.contentTintColor = showsHiddenFiles ? accent : foreground
        separator.fillColor = foreground.withAlphaComponent(0.12)
        // Updating existing views preserves selection, expansion, and scroll position.
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileTreeNode,
               let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView {
                style(cell, for: node)
            }
            if let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? FileTreeRowView {
                rowView.accent = accent
                rowView.needsDisplay = true
            }
        }
    }

    private func configureViews() {
        wantsLayer = true
        setAccessibilityLabel("Workspace files")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(folderButton, symbol: "folder", label: "Open Folder", action: #selector(chooseFolder))
        configure(refreshButton, symbol: "arrow.clockwise", label: "Refresh Files", action: #selector(refreshClicked))
        configure(hiddenButton, symbol: "eye.slash", label: "Show Hidden and Excluded Files", action: #selector(toggleHidden))
        hiddenButton.toolTip = "Show hidden files and excluded folders (.git, .build, build, node_modules)"
        refreshButton.isEnabled = false

        let header = NSStackView(views: [titleLabel, folderButton, refreshButton, hiddenButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 3
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 7)

        separator.boxType = .custom
        separator.borderWidth = 0
        separator.contentViewMargins = .zero
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("File"))
        column.title = "Files"
        column.minWidth = 40
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openClickedItem)
        outline.rowHeight = 26
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.indentationPerLevel = 15
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.focusRingType = .none
        outline.style = .plain
        outline.setAccessibilityLabel("Workspace file tree")
        outline.makeContextMenu = { [weak self] row in self?.contextMenu(at: row) }
        outline.openSelection = { [weak self] in self?.openSelectedItem() }
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        for view in [header, separator, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 42),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        applyTheme(background: .controlBackgroundColor, foreground: .labelColor, accent: .controlAccentColor)
        outline.reloadData()
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        let width = button.widthAnchor.constraint(equalToConstant: 25)
        width.priority = .defaultHigh // The owning split view may collapse this panel to zero.
        width.isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func reset(to url: URL?, preservingState: Bool) {
        if preservingState {
            if let selection = outline.item(atRow: outline.selectedRow) as? FileTreeNode,
               let path = selection.url?.path { pendingSelection = path }
        } else {
            expandedPaths.removeAll()
            pendingSelection = nil
        }
        generation = UUID()
        reads.cancelAllOperations()
        reportedReadError = false
        nodes.removeAll()
        root = url.map { FileTreeNode(url: $0, kind: .folder, identity: nil) }
        if let root, let path = root.url?.path { nodes[path] = root }
        titleLabel.stringValue = url.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent } ?? "Workspace"
        titleLabel.toolTip = url?.path
        refreshButton.isEnabled = url != nil
        reloading = true
        outline.reloadData()
        reloading = false
        if let root { load(root) }
    }

    private func load(_ node: FileTreeNode) {
        guard node.kind == .folder, node.state == .unloaded || node.state == .failed,
              let url = node.url, let workspace = rootURL else { return }
        let token = UUID()
        let version = generation
        let includeHidden = showsHiddenFiles
        let requiredPaths=self.requiredPaths
        let expectedIdentity = node.identity
        let rootIdentity = root?.identity
        node.state = .loading
        node.request = token
        node.children = [FileTreeNode(message: "Loading…", parent: node)]
        // No reload here: this can be called during NSOutlineView's expansion callback.
        let job = BlockOperation()
        job.addExecutionBlock { [weak self, weak job] in
            guard let job, !job.isCancelled else { return }
            let result = Result {
                try FileTreeDisk.read(url, root: workspace, rootIdentity: rootIdentity,
                                      expectedIdentity: expectedIdentity, includeHidden: includeHidden, requiredPaths:requiredPaths,
                                      isCancelled: { job.isCancelled })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == version,
                      let current = self.nodes[url.path], current.request == token else { return }
                current.request = nil
                if requiredPaths != self.requiredPaths {current.state = .unloaded;self.load(current);return}
                switch result {
                case .success(let listing):
                    current.state = .loaded
                    current.identity = listing.identity
                    current.children = listing.entries.map { entry in
                        let child = FileTreeNode(url: entry.url, kind: entry.kind, identity: entry.identity)
                        child.parent = current
                        self.nodes[entry.url.path] = child
                        return child
                    }
                    if current.children.isEmpty {
                        current.children = [FileTreeNode(message: "No visible files", parent: current)]
                    }
                case .failure(let error):
                    current.state = .failed
                    current.children = [FileTreeNode(message: "Couldn’t load folder — double-click to retry", parent: current)]
                    if !self.reportedReadError && (current === self.root || self.outline.isItemExpanded(current)) {
                        self.reportedReadError = true
                        self.showError("Couldn’t Read Folder", detail: "\(url.path)\n\n\(error.localizedDescription)")
                    }
                }
                self.reloading = true
                self.outline.reloadItem(current === self.root ? nil : current, reloadChildren: true)
                self.reloading = false
                self.restoreState(below: current)
            }
        }
        reads.addOperation(job)
    }

    private func restoreState(below node: FileTreeNode) {
        guard node === root || outline.isItemExpanded(node) else { return }
        for child in node.children {
            guard let path = child.url?.path else { continue }
            if child.kind == .folder && expandedPaths.contains(path) {
                load(child)
                outline.expandItem(child)
            }
            if path == pendingSelection {
                let row = outline.row(forItem: child)
                if row >= 0 {
                    reloading = true
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    reloading = false
                    outline.scrollRowToVisible(row)
                    pendingSelection = nil
                }
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileTreeNode ?? root)?.children.count ?? 1
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FileTreeNode ?? root)?.children[index] ?? emptyNode
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileTreeNode)?.kind == .folder
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FileTreeNode, node.kind == .folder else { return false }
        load(node)
        return true
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileTreeNode else { return }
        load(node) // Covers programmatic as well as user expansion.
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !reloading, let node = notification.userInfo?["NSObject"] as? FileTreeNode,
              let path = node.url?.path else { return }
        expandedPaths.insert(path)
        restoreState(below: node)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !reloading, let node = notification.userInfo?["NSObject"] as? FileTreeNode,
              let path = node.url?.path else { return }
        expandedPaths.remove(path)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !reloading { pendingSelection = nil }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? FileTreeNode)?.url != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileTreeCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyDown
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            for view in [icon, label] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            cell.imageView = icon
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = node.name
        cell.toolTip = node.url.map { $0.path + (node.kind == .link ? "\nSymbolic link (not followed)" : "") } ?? node.name
        cell.imageView?.image = icon(for: node)
        style(cell, for: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = FileTreeRowView()
        row.accent = accent
        return row
    }

    private func style(_ cell: NSTableCellView, for node: FileTreeNode) {
        let opened=node.url.map{openPaths.contains($0.path)} ?? false
        let active=node.url?.path == activePath
        cell.textField?.stringValue=(opened ? "•  ":"")+node.name
        cell.textField?.font = .systemFont(ofSize:12,weight:opened ? .medium:.regular)
        cell.textField?.textColor = opened ? accent.withAlphaComponent(active ? 1:0.78):(node.url == nil ? foreground.withAlphaComponent(0.6):foreground)
        cell.setAccessibilityLabel(node.name+(opened ? ", open in editor":""))
        cell.imageView?.contentTintColor = node.kind == .folder ? accent : foreground.withAlphaComponent(0.75)
    }

    private func icon(for node: FileTreeNode) -> NSImage? {
        switch node.kind {
        case .folder: return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
        case .link: return NSImage(systemSymbolName: "link", accessibilityDescription: "Symbolic link")
        case .message: return nil
        case .file:
            let ext = node.url?.pathExtension.lowercased() ?? ""
            if let cached = iconCache[ext] { return cached }
            let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
            iconCache[ext] = image
            return image
        }
    }

    @objc private func chooseFolder() {
        if let onChooseFolder { onChooseFolder(); return }
        let picker = NSOpenPanel()
        picker.title = "Open Workspace Folder"
        picker.prompt = "Open Folder"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.resolvesAliases = false
        picker.directoryURL = rootURL
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak picker] response in
            if response == .OK, let url = picker?.url { self?.setRoot(url) }
        }
        if let window { picker.beginSheetModal(for: window, completionHandler: completion) }
        else { picker.begin(completionHandler: completion) }
    }

    @objc private func refreshClicked() { refresh() }

    @objc private func toggleHidden() {
        showsHiddenFiles.toggle()
        hiddenButton.image = NSImage(systemSymbolName: showsHiddenFiles ? "eye" : "eye.slash", accessibilityDescription: nil)
        let label = showsHiddenFiles ? "Hide Hidden and Excluded Files" : "Show Hidden and Excluded Files"
        hiddenButton.setAccessibilityLabel(label)
        hiddenButton.toolTip = label + " (.git, .build, build, node_modules)"
        hiddenButton.contentTintColor = showsHiddenFiles ? accent : foreground
        refresh()
    }

    @objc private func openClickedItem() {
        guard outline.clickedRow >= 0 else { return }
        activate(outline.item(atRow: outline.clickedRow) as? FileTreeNode)
    }

    private func openSelectedItem() {
        guard outline.selectedRow >= 0 else { return }
        activate(outline.item(atRow: outline.selectedRow) as? FileTreeNode)
    }

    private func activate(_ node: FileTreeNode?) {
        guard let node else { return }
        switch node.kind {
        case .folder:
            if outline.isItemExpanded(node) { outline.collapseItem(node) }
            else { load(node); outline.expandItem(node) }
        case .file:
            guard onOpenFile != nil, let url = node.url, let workspace = rootURL else { return }
            let target = FileTreeTarget(url: url, root: workspace, identity: node.identity,
                                        rootIdentity: root?.identity, generation: generation)
            reads.addOperation { [weak self] in
                let result = Result { try FileTreeDisk.checkFile(target) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == target.generation else { return }
                    switch result {
                    case .success: self.onOpenFile?(target.url)
                    case .failure(let error):
                        self.showError("Couldn’t Open File", detail: "\(url.path)\n\n\(error.localizedDescription)")
                    }
                }
            }
        case .message:
            if let parent = node.parent, parent.state == .failed {
                load(parent)
                outline.reloadItem(parent === root ? nil : parent, reloadChildren: true)
            }
        case .link: break // Links are visible leaves, never traversed or opened.
        }
    }

    private func contextMenu(at row: Int) -> NSMenu? {
        guard let root, let rootURL = root.url else { return nil }
        let clicked = row >= 0 ? outline.item(atRow: row) as? FileTreeNode : nil
        let node = clicked?.url != nil ? clicked : clicked?.parent
        let directory = node?.kind == .folder ? node : node?.parent ?? root
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, node: FileTreeNode?, mutating: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let url = node?.url {
                item.representedObject = FileTreeTarget(url: url, root: rootURL,
                    identity: node?.identity, rootIdentity: root.identity, generation: generation)
            }
            item.isEnabled = !mutating || (!operationInProgress && root.identity != nil && node?.identity != nil)
            menu.addItem(item)
        }
        if let node,node.kind == .file,onOpenFileInNewWindow != nil {add("Open in New Window",#selector(openNewWindow(_:)),node:node);menu.addItem(.separator())}
        add("New File…", #selector(newFile(_:)), node: directory, mutating: true)
        add("New Folder…", #selector(newFolder(_:)), node: directory, mutating: true)
        if let node, node !== root, node.url != nil {
            menu.addItem(.separator())
            add("Rename…", #selector(renameItem(_:)), node: node, mutating: true)
            add("Move to Trash…", #selector(trashItem(_:)), node: node, mutating: true)
        }
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(revealItem(_:)), node: node ?? root)
        add("Refresh", #selector(refreshClicked), node: nil)
        return menu
    }

    private func target(_ sender: NSMenuItem) -> FileTreeTarget? {
        guard let target = sender.representedObject as? FileTreeTarget,
              target.generation == generation, target.root == rootURL else { return nil }
        return target
    }

    @objc private func openNewWindow(_ sender:NSMenuItem) {guard let target=target(sender) else{return};onOpenFileInNewWindow?(target.url)}

    @objc private func newFile(_ sender: NSMenuItem) {
        guard let target = target(sender) else { return }
        promptForName(title: "New File", name: "untitled.txt", target: target, operation: .newFile)
    }

    @objc private func newFolder(_ sender: NSMenuItem) {
        guard let target = target(sender) else { return }
        promptForName(title: "New Folder", name: "New Folder", target: target, operation: .newFolder)
    }

    @objc private func renameItem(_ sender: NSMenuItem) {
        guard let target = target(sender) else { return }
        promptForName(title: "Rename", name: target.url.lastPathComponent, target: target, operation: .rename)
    }

    private func promptForName(title: String, name: String, target: FileTreeTarget, operation: FileTreeDisk.Operation) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = target.url.path
        alert.addButton(withTitle: operation == .rename ? "Rename" : "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = name
        field.setAccessibilityLabel("Name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        field.selectText(nil)
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  self.rootURL == target.root, self.generation == target.generation else { return }
            let newName = field.stringValue
            guard FileTreeDisk.validName(newName) else {
                self.showError("Invalid Name", detail: "Use a nonempty name other than “.” or “..”, without /, :, or a null character.")
                return
            }
            if operation == .rename && newName == target.url.lastPathComponent { return }
            self.perform(operation, target: target, name: newName)
        }
    }

    @objc private func trashItem(_ sender: NSMenuItem) {
        guard let target = target(sender), target.url != target.root else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move “\(target.url.lastPathComponent)” to the Trash?"
        alert.informativeText = "\(target.url.path)\n\nFolders include all their contents. You can restore this item from the Trash in Finder."
        // Cancel is the default, so Return can never accidentally confirm deletion.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        present(alert) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self,
                  self.rootURL == target.root, self.generation == target.generation else { return }
            self.perform(.trash, target: target, name: "")
        }
    }

    @objc private func revealItem(_ sender: NSMenuItem) {
        guard let target = target(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target.url])
    }

    private func perform(_ operation: FileTreeDisk.Operation, target: FileTreeTarget, name: String) {
        guard !operationInProgress else { return }
        operationInProgress = true
        mutations.async { [weak self] in
            let result = Result { try FileTreeDisk.perform(operation, target: target, name: name) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.operationInProgress = false
                switch result {
                case .success(let destination):
                    if self.rootURL == target.root {
                        if let destination {
                            if operation == .rename {
                                // Preserve expanded descendants when their parent is renamed.
                                let old = target.url.path
                                self.expandedPaths = Set(self.expandedPaths.map {
                                    $0 == old || $0.hasPrefix(old + "/") ? destination.path + $0.dropFirst(old.count) : $0
                                })
                            }
                            self.expandedPaths.insert(destination.deletingLastPathComponent().path)
                        }
                        self.refresh()
                        self.pendingSelection = destination?.path
                    }
                    // Report completed mutations even if the workspace changed in flight.
                    // Call the host last, so it can safely change the root or refresh again.
                    switch operation {
                    case .rename:
                        if let destination { self.onMove?(target.url, destination) }
                    case .trash:
                        self.onTrash?(target.url)
                    case .newFile, .newFolder:
                        break
                    }
                case .failure(let error):
                    self.showError("Couldn’t \(operation.title)", detail: "\(target.url.path)\n\n\(error.localizedDescription)")
                }
            }
        }
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        present(alert) { _ in }
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        alerts.append((alert, completion))
        presentNextAlert()
    }

    private func presentNextAlert() {
        guard !showingAlert, !alerts.isEmpty else { return }
        showingAlert = true
        let (alert, completion) = alerts.removeFirst()
        let finished: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            completion(response)
            self?.showingAlert = false
            self?.presentNextAlert()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finished) }
        else { finished(alert.runModal()) }
    }
}

@MainActor
private final class FileTreeNode: NSObject {
    enum State { case unloaded, loading, loaded, failed }
    let url: URL?
    let name: String
    let kind: FileTreeDisk.Kind
    var identity: FileTreeDisk.Identity?
    weak var parent: FileTreeNode?
    var children: [FileTreeNode] = []
    var state = State.unloaded
    var request: UUID?

    init(url: URL, kind: FileTreeDisk.Kind, identity: FileTreeDisk.Identity?) {
        self.url = url
        self.name = url.lastPathComponent
        self.kind = kind
        self.identity = identity
        super.init()
        if kind == .folder { children = [FileTreeNode(message: "Loading…", parent: self)] }
    }

    init(message: String, parent: FileTreeNode? = nil) {
        url = nil
        name = message
        kind = .message
        self.parent = parent
        super.init()
        state = .loaded
    }
}

@MainActor
private final class FileTreeOutlineView: NSOutlineView {
    var makeContextMenu: ((Int) -> NSMenu?)?
    var openSelection: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, let item = item(atRow: row), delegate?.outlineView?(self, shouldSelectItem: item) != false {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return makeContextMenu?(row)
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            openSelection?()
        } else { super.keyDown(with: event) }
    }
}

@MainActor
private final class FileTreeRowView: NSTableRowView {
    var accent = NSColor.controlAccentColor

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        accent.withAlphaComponent(isEmphasized ? 0.24 : 0.13).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}

private struct FileTreeTarget: Sendable {
    let url: URL
    let root: URL
    let identity: FileTreeDisk.Identity?
    let rootIdentity: FileTreeDisk.Identity?
    let generation: UUID
}

/// Value-only worker code. Descriptor-relative reads/creates/renames prevent
/// replacement of an intermediate folder with a symlink from escaping the tree.
private enum FileTreeDisk {
    enum Kind: Sendable { case folder, file, link, message }
    struct Identity: Sendable, Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }
    struct Entry: Sendable {
        let url: URL
        let kind: Kind
        let identity: Identity
    }
    struct Listing: Sendable {
        let identity: Identity
        let entries: [Entry]
    }
    enum Operation: Sendable {
        case newFile, newFolder, rename, trash
        var title: String {
            switch self {
            case .newFile: return "Create File"
            case .newFolder: return "Create Folder"
            case .rename: return "Rename Item"
            case .trash: return "Move Item to Trash"
            }
        }
    }

    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains(":") && !name.utf8.contains(0)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Lumen.FileTree", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func verify(_ actual: stat, expected: Identity?) throws {
        if let expected, Identity(actual) != expected {
            throw failure("This item changed on disk. Refresh the file tree and try again.")
        }
    }

    private static func withDirectory<T>(_ url: URL, root: URL, rootIdentity: Identity?,
                                         body: (Int32) throws -> T) throws -> T {
        let base = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: base) else { throw failure("The folder is outside this workspace.") }
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        try verify(info, expected: rootIdentity)
        for component in components.dropFirst(base.count) {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw posixError() }
            close(fd)
            fd = next
        }
        return try body(fd)
    }

    static func read(_ url: URL, root: URL, rootIdentity: Identity?, expectedIdentity: Identity?,
                     includeHidden: Bool, requiredPaths:Set<String> = [], isCancelled: @Sendable () -> Bool = { false }) throws -> Listing {
        try withDirectory(url, root: root, rootIdentity: rootIdentity) { fd in
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw posixError() }
            try verify(info, expected: expectedIdentity)
            let copy = dup(fd)
            guard copy >= 0 else { throw posixError() }
            guard let directory = fdopendir(copy) else {
                let error = posixError()
                close(copy)
                throw error
            }
            defer { closedir(directory) }
            var entries: [Entry] = []
            while true {
                if isCancelled() { throw CancellationError() }
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw posixError() }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                if !includeHidden && !requiredPaths.contains(url.appendingPathComponent(name).path) && (name.hasPrefix(".") || name == "build" || name == "node_modules") { continue }
                var metadata = stat()
                guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue } // A concurrent removal is harmless.
                    throw posixError()
                }
                if !includeHidden && !requiredPaths.contains(url.appendingPathComponent(name).path) && metadata.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
                let type = metadata.st_mode & mode_t(S_IFMT)
                let kind: Kind = type == mode_t(S_IFLNK) ? .link : (type == mode_t(S_IFDIR) ? .folder : .file)
                entries.append(Entry(url: url.appendingPathComponent(name, isDirectory: kind == .folder),
                                     kind: kind, identity: Identity(metadata)))
            }
            entries.sort {
                if ($0.kind == .folder) != ($1.kind == .folder) { return $0.kind == .folder }
                let comparison = $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
                return comparison == .orderedSame ? $0.url.path < $1.url.path : comparison == .orderedAscending
            }
            return Listing(identity: Identity(info), entries: entries)
        }
    }

    static func checkFile(_ target: FileTreeTarget) throws {
        try withDirectory(target.url.deletingLastPathComponent(), root: target.root, rootIdentity: target.rootIdentity) { fd in
            var info = stat()
            guard fstatat(fd, target.url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
            try verify(info, expected: target.identity)
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw failure("Only regular files can be opened. Symbolic links are not followed.")
            }
        }
    }

    static func perform(_ operation: Operation, target: FileTreeTarget, name: String) throws -> URL? {
        guard operation == .trash || validName(name) else { throw failure("Invalid name.") }
        let creating = operation == .newFile || operation == .newFolder
        guard creating || target.url != target.root else { throw failure("The workspace root cannot be renamed or trashed.") }
        let parent = creating ? target.url : target.url.deletingLastPathComponent()
        return try withDirectory(parent, root: target.root, rootIdentity: target.rootIdentity) { fd in
            var info = stat()
            let result = creating ? fstat(fd, &info) : fstatat(fd, target.url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW)
            guard result == 0 else { throw posixError() }
            try verify(info, expected: target.identity)
            let isDirectory = operation == .newFolder
                || (operation == .rename && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
            let destination = parent.appendingPathComponent(name, isDirectory: isDirectory)
            switch operation {
            case .newFile:
                let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o666))
                guard file >= 0 else { throw posixError() }
                close(file)
            case .newFolder:
                guard mkdirat(fd, name, mode_t(0o777)) == 0 else { throw posixError() }
            case .rename:
                // RENAME_EXCL gives an atomic no-overwrite guarantee, even if a
                // destination appears after the user accepted the name dialog.
                guard renameatx_np(fd, target.url.lastPathComponent, fd, name, UInt32(RENAME_EXCL)) == 0 else {
                    throw posixError()
                }
            case .trash:
                // Foundation has no descriptor-relative Trash API. Revalidate the
                // path immediately before asking Finder's recoverable trash service.
                try withDirectory(parent, root: target.root, rootIdentity: target.rootIdentity) { checkedFD in
                    var checked = stat()
                    guard fstatat(checkedFD, target.url.lastPathComponent, &checked, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
                    try verify(checked, expected: target.identity)
                    _ = try FileManager.default.trashItem(at: target.url, resultingItemURL: nil)
                }
                return nil // Never fall back to removeItem/unlink if Trash fails.
            }
            return destination
        }
    }
}
