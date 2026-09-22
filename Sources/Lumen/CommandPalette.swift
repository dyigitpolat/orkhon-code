import AppKit

struct PaletteItem: Sendable {
    let title: String
    let subtitle: String
    let shortcut: String
    let identifier: String

    init(title: String, subtitle: String, shortcut: String, identifier: String) {
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.identifier = identifier
    }
}

/// Retain this controller in the host while it is presented. If onSelect refers
/// to that host, capture it weakly. The same controller can be presented again.
@MainActor
final class CommandPalette: NSWindowController, NSWindowDelegate,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private let items: [PaletteItem]
    private let onSelect: (PaletteItem) -> Void
    private let disposeWindow: @MainActor @Sendable () -> Void
    private let searchField = NSSearchField()
    private let tableView = PaletteTableView()
    private let scrollView = NSScrollView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var visibleIndices: [Int] = []
    private var filterTask: Task<Void, Never>?
    private var generation = 0
    private var isPresented = false

    init(parent: NSWindow, title: String, placeholder: String,
         items: [PaletteItem], compact: Bool = false, onSelect: @escaping (PaletteItem) -> Void) {
        self.parent = parent
        self.items = items
        self.onSelect = onSelect
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: compact ? 440 : 600, height: compact ? 360 : 400),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        disposeWindow = {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        super.init(window: panel)
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.animationBehavior = .utilityWindow
        panel.appearance = parent.effectiveAppearance
        panel.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        buildContent(title: title, placeholder: placeholder)
        if compact { tableView.rowHeight=44;tableView.action=#selector(openClickedRow(_:));tableView.doubleAction=nil }
        NotificationCenter.default.addObserver(self, selector: #selector(parentWillClose),
                                               name: NSWindow.willCloseNotification, object: parent)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(parent:title:placeholder:items:onSelect:)") }

    deinit {
        filterTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        // Child windows belong to their parent; remove ours if the host releases us.
        let dispose = disposeWindow
        if Thread.isMainThread {
            MainActor.assumeIsolated { dispose() }
        } else {
            Task { @MainActor in dispose() }
        }
    }

    func present() {
        guard let parent, let window else { return }
        if isPresented {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(searchField)
            return
        }
        // Do not place a palette in front of an unrelated modal sheet.
        guard parent.attachedSheet == nil else { return }
        previousResponder = parent.firstResponder
        window.appearance = parent.effectiveAppearance
        window.level = parent.level
        let parentRect = parent.convertToScreen(parent.contentLayoutRect)
        var frame = window.frame
        frame.origin = NSPoint(x: parentRect.midX - frame.width / 2,
                               y: parentRect.midY - frame.height / 2)
        if let screen = parent.screen {
            let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        }
        window.setFrame(frame, display: false)
        searchField.stringValue = ""
        isPresented = true
        filter()
        parent.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
    }

    override func close() { dismiss(restoreFocus: true) }

    override func cancelOperation(_ sender: Any?) { close() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowDidResignKey(_ notification: Notification) { dismiss(restoreFocus: false) }

    @objc private func parentWillClose(_ notification: Notification) { dismiss(restoreFocus: false) }

    private func dismiss(restoreFocus: Bool) {
        guard isPresented, let window else { return }
        isPresented = false
        generation += 1
        filterTask?.cancel()
        filterTask = nil
        let wasKey = window.isKeyWindow
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        if restoreFocus, wasKey, let parent, parent.isVisible {
            parent.makeKey()
            if let previousResponder { parent.makeFirstResponder(previousResponder) }
        }
        previousResponder = nil
    }

    private func buildContent(title: String, placeholder: String) {
        guard let window else { return }
        let content = NSVisualEffectView()
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        window.contentView = content

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingTail
        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(),
                                   target: self, action: #selector(closeButtonPressed(_:)))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close (Esc)"
        closeButton.setAccessibilityLabel("Close palette")

        searchField.placeholderString = placeholder
        searchField.font = .systemFont(ofSize: 16)
        searchField.controlSize = .large
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.maximumRecents = 0
        searchField.setAccessibilityLabel(placeholder.isEmpty ? title : placeholder)
        searchField.setAccessibilityHelp("Type to filter. Use Up and Down to choose, Return to open, Escape to close.")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.style = .plain
        tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow(_:))
        tableView.onAccept = { [weak self] in self?.acceptSelection() }
        tableView.onCancel = { [weak self] in self?.close() }
        tableView.setAccessibilityLabel("\(title) results")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let topRule = NSBox()
        topRule.boxType = .separator
        let bottomRule = NSBox()
        bottomRule.boxType = .separator
        emptyTitle.font = .systemFont(ofSize: 14, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.lineBreakMode = .byTruncatingTail
        let emptyState = NSStackView(views: [emptyTitle, emptyDetail])
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 6
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let hints = NSTextField(labelWithString: "↑↓ Navigate   ↩ Open   esc Close")
        hints.font = .systemFont(ofSize: 11)
        hints.textColor = .secondaryLabelColor
        hints.setAccessibilityLabel("Arrow keys to navigate, Return to open, Escape to close")

        for view in [heading, closeButton, searchField, topRule, scrollView, emptyState, bottomRule, statusLabel, hints] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 15),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            searchField.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 32),
            topRule.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            topRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bottomRule.topAnchor, constant: -4),
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
            bottomRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -32),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.centerYAnchor.constraint(equalTo: hints.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: hints.leadingAnchor, constant: -12),
            hints.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            hints.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        window.initialFirstResponder = searchField
        searchField.nextKeyView = tableView
        tableView.nextKeyView = closeButton
        closeButton.nextKeyView = searchField
    }

    @objc private func closeButtonPressed(_ sender: Any?) { close() }

    @objc private func openClickedRow(_ sender: Any?) {
        guard visibleIndices.indices.contains(tableView.clickedRow) else { return }
        tableView.selectRowIndexes(IndexSet(integer: tableView.clickedRow), byExtendingSelection: false)
        acceptSelection()
    }

    private func acceptSelection() {
        guard isPresented, visibleIndices.indices.contains(tableView.selectedRow) else { return }
        let item = items[visibleIndices[tableView.selectedRow]]
        // Dismiss before invoking host actions, which may open another window or palette.
        dismiss(restoreFocus: true)
        onSelect(item)
    }

    func controlTextDidChange(_ obj: Notification) {
        // Let input methods finish composing before changing the candidate list.
        guard (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        filter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            acceptSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    private func moveSelection(by delta: Int) {
        guard !visibleIndices.isEmpty else { return }
        let row = tableView.selectedRow < 0 ? 0 : min(max(tableView.selectedRow + delta, 0), visibleIndices.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleIndices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleIndices.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("PaletteCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PaletteCell ?? PaletteCell()
        cell.identifier = identifier
        cell.configure(items[visibleIndices[row]])
        return cell
    }

    private func filter() {
        filterTask?.cancel()
        filterTask = nil
        generation += 1
        let currentGeneration = generation
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            apply(PaletteMatches(indices: Array(items.indices.prefix(PaletteMatcher.limit)), total: items.count),
                  generation: currentGeneration)
        } else if items.count <= 5_000 {
            if let matches = PaletteMatcher.filter(items, query: query) {
                apply(matches, generation: currentGeneration)
            }
        } else {
            // Clear stale selection so Return cannot activate a result for an older query.
            visibleIndices = []
            tableView.reloadData()
            tableView.deselectAll(nil)
            setEmptyState(title: "Searching…", detail: "Finding matching items")
            statusLabel.stringValue = "Searching…"
            filterTask = Task.detached(priority: .userInitiated) { [weak self, items] in
                // Coalesce quick edits; cancellation also interrupts the matching loop.
                do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return }
                guard let matches = PaletteMatcher.filter(items, query: query), !Task.isCancelled else { return }
                await self?.apply(matches, generation: currentGeneration)
            }
        }
    }

    private func apply(_ matches: PaletteMatches, generation: Int) {
        guard isPresented, self.generation == generation else { return }
        filterTask = nil
        visibleIndices = matches.indices
        tableView.reloadData()
        tableView.deselectAll(nil)
        if !visibleIndices.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        setEmptyState(title: items.isEmpty ? "No items available" : "No matches",
                      detail: items.isEmpty ? "Items will appear here when supplied by the editor." : "Try a different name or part of a path.")
        let noun = matches.total == 1 ? "result" : "results"
        statusLabel.stringValue = matches.total > visibleIndices.count
            ? "\(matches.total) \(noun) · First \(visibleIndices.count) shown"
            : "\(matches.total) \(noun)"
        statusLabel.toolTip = matches.total > visibleIndices.count ? "Keep typing to narrow the results." : nil
    }

    private func setEmptyState(title: String, detail: String) {
        emptyTitle.stringValue = title
        emptyDetail.stringValue = detail
        emptyTitle.superview?.isHidden = !visibleIndices.isEmpty
        scrollView.isHidden = visibleIndices.isEmpty
    }
}

private final class PaletteTableView: NSTableView {
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onAccept?() // Return and keypad Enter when the table has focus.
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class PaletteCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        textField = titleLabel
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.alignment = .right
        shortcutLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(751), for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(751), for: .horizontal)
        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        for view in [labels, shortcutLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor, constant: -16),
            titleLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcutLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 140)
        ])
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    func configure(_ item: PaletteItem) {
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle
        subtitleLabel.isHidden = item.subtitle.isEmpty
        shortcutLabel.stringValue = item.shortcut
        toolTip = [item.title, item.subtitle, item.shortcut].filter { !$0.isEmpty }.joined(separator: "\n")
        setAccessibilityLabel([item.title, item.subtitle, item.shortcut].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        titleLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        subtitleLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        shortcutLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}

private struct PaletteMatches: Sendable {
    let indices: [Int]
    let total: Int
}

/// Pure value-based matching: no filesystem access or AppKit work on the worker.
private enum PaletteMatcher {
    static let limit = 200

    static func filter(_ items: [PaletteItem], query: String) -> PaletteMatches? {
        let tokens = normalized(query).split(whereSeparator: { $0.isWhitespace }).map { Array($0) }
        guard !tokens.isEmpty else {
            return PaletteMatches(indices: Array(items.indices.prefix(limit)), total: items.count)
        }
        var matches: [(index: Int, score: Int)] = []
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return nil }
            let title = Array(normalized(item.title))
            let subtitle = Array(normalized(item.subtitle))
            var total = 0
            var matched = true
            for token in tokens {
                let titleScore = score(token, in: title).map { $0 + 200 }
                let subtitleScore = score(token, in: subtitle)
                guard let best = [titleScore, subtitleScore].compactMap({ $0 }).max() else {
                    matched = false
                    break
                }
                total += best
            }
            if matched { matches.append((index, total)) }
        }
        guard !Task.isCancelled else { return nil }
        matches.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        return PaletteMatches(indices: matches.prefix(limit).map(\.index), total: matches.count)
    }

    private static func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                       locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func score(_ query: [Character], in candidate: [Character]) -> Int? {
        guard query.count <= candidate.count else { return nil }
        var next = 0
        var first = 0
        var previous = -1
        var points = 0
        for (position, character) in candidate.enumerated() where character == query[next] {
            if next == 0 { first = position }
            points += 16
            if position == 0 || !candidate[position - 1].isLetter && !candidate[position - 1].isNumber {
                points += 24 // Word/path boundaries.
            }
            if next > 0, position == previous + 1 { points += 28 }
            previous = position
            next += 1
            if next == query.count {
                if candidate == query { points += 1_000 }
                else if first == 0, position + 1 == query.count { points += 600 }
                else if position - first + 1 == query.count { points += 350 }
                // Prefer compact matches and shorter names without excluding long paths.
                points -= min(first, 60) + min(position - first + 1 - query.count, 100)
                points -= min(candidate.count - query.count, 80)
                return points
            }
        }
        return nil
    }
}
