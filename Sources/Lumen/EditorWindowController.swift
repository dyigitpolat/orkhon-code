import AppKit
import EditorBridge
import LumenCore

@MainActor
final class DocumentTab {
    let id=UUID().uuidString
    var url: URL?
    var format: TextFile?
    let editor: LMEditorView
    var language: Language?
    var pinned=false
    var isWelcome=false
    var previewAssetRevision:UInt64=0
    var previewMode=PreviewMode.source
    var previewingMarkdown:Bool {get{previewMode != .source} set{previewMode=newValue ? .preview:.source}}
    var remotePath:String?
    var languageOverride=false
    var loading=false
    var recoveryWork: DispatchWorkItem?
    var displayedDirty=false
    var baselineChanged=false,checkingExternal=false
    var externalChange:ExternalChange?
    var externalHighlights:ExternalChange?
    var externalReviewRequested=false
    var externalAnchors:[ExternalAnchor]=[]
    var isModified:Bool {baselineChanged || editor.modified}
    init() { editor=LMEditorView(frame:.zero) }
    var title:String { isWelcome ? "Welcome" : (remotePath.map{($0 as NSString).lastPathComponent} ?? url?.lastPathComponent ?? "Untitled") }
}

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    weak var coordinator:ApplicationCoordinator?
    var window: NSWindow!
    let root=Surface(), header=TitleBarSurface(), tabsSurface=Surface(), statusSurface=Surface(), editorSurface=Surface()
    let tabScroll=TabScrollView(), tabStack=NSStackView()
    let tabBack=NSButton(), tabForward=NSButton(), allTabs=NSButton()
    var manualWorkspace=false
    let editorSplit=PaneSplitView(frame:.zero),firstPane=EditorPane(frame:.zero),secondPane=EditorPane(frame:.zero)
    var previewDeck:PreviewDeck {activePane.deck}
    var markdownView:MarkdownView? {activePane.markdown}
    var sshWindow:SSHConnectionPanel?
    var remote:RemoteWorkspace?
    var remoteTree:RemoteTreePanel?
    let mainSplit=NSSplitViewController(), workSplit=NSSplitViewController()
    var treeItem:NSSplitViewItem!, terminalItem:NSSplitViewItem!
    let treeHost=NSView()
    var tree:FileTreePanel?
    var workspaceURL:URL?
    var terminal:TerminalPanel?
    let terminalHost=NSView()
    var documents:[DocumentTab]=[]
    var selected:Int = -1
    var current:DocumentTab? { documents.indices.contains(selected) ? documents[selected] : nil }
    var theme=Theme.all[UserDefaults.standard.integer(forKey:"theme").clamped(to:0...3)]
    let themePicker=NSButton()
    var themeWindow:CommandPalette?
    let languagePicker=NSButton()
    let status=NSTextField(labelWithString:""), brand=BrandMark(frame:.zero)
    let pathLabel=NSTextField(labelWithString:"new document: here is a little room to think.")
    let findBar=Surface(), findInput=Surface(), replaceInput=Surface(), findField=CenteredTextField(), replaceField=CenteredTextField()
    let caseToggle=PillButton(title:"Aa",target:nil,action:nil), regexToggle=PillButton(title:".*",target:nil,action:nil), wordToggle=PillButton(title:"ab",target:nil,action:nil)
    let findResult=NSTextField(labelWithString:"")
    var showFind=false, showReplace=false, wrap=UserDefaults.standard.bool(forKey:"wordWrap"), whitespace=false
    var fontSize:CGFloat { get { CGFloat(UserDefaults.standard.double(forKey:"fontSize")).clamped(to:10...28) } set { UserDefaults.standard.set(Double(newValue),forKey:"fontSize") } }
    let fileMonitor=FileChangeMonitor(),remoteMonitor=RemoteChangeMonitor()
    let localWorkspaceRefresh=PreviewRefresh(idle:1,maxDelay:3),remoteWorkspaceRefresh=PreviewRefresh(idle:1,maxDelay:3)
    var localTreeDirty=false,remoteTreeDirty=false
    var remoteCheckPending=false
    var remoteCheckCompletions:[()->Void]=[]
    var externalCheck:DispatchWorkItem?
    var remotePollTimer:Timer?
    var remotePollInFlight=false,lastRemotePoll:TimeInterval=0
    let externalBar=Surface(),externalLabel=NSTextField(labelWithString:""),externalButton=PillButton(title:"Next conflict",target:nil,action:nil)
    let ioQueue=DispatchQueue(label:"app.lumen.files",qos:.userInitiated)
    let recoveryQueue=DispatchQueue(label:"app.lumen.recovery",qos:.utility)
    var paletteWindow:CommandPalette?
    var setupWindow:NSWindowController?
    var languageWindow:CommandPalette?
    var recentFilesMenu=NSMenu(title:"Open Recent")
    var launched=false, restoring=false, pendingURLs:[URL]=[]
    var suppressSessionRestore=false
    var automatedTesting:Bool {
        ProcessInfo.processInfo.environment["ORKHON_TEST_DATA"] != nil &&
        ProcessInfo.processInfo.environment["ORKHON_PAUSE_INLINE_TEST"] != "1" &&
        CommandLine.arguments.contains(where:{["--self-test","--revision-tests","--startup-tests"].contains($0)})
    }
    var recoveryURL:URL { if let path=ProcessInfo.processInfo.environment["ORKHON_TEST_DATA"] { return URL(fileURLWithPath:path).appendingPathComponent("Recovery") }; return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Orkhon Editor/Recovery",isDirectory:true) }
    var sessionURL:URL { recoveryURL.deletingLastPathComponent().appendingPathComponent("session.json") }

    func applicationDidFinishLaunching(_ notification:Notification) {
        startupTrace("didFinishLaunching")
        UserDefaults.standard.register(defaults:["fontSize":14.0,"tabWidth":4,"spaces":true])
        buildMenus();startupTrace("menus");buildWindow();startupTrace("window");newDocument(nil);startupTrace("editor")
        launched=true
        window.makeKeyAndOrderFront(nil);startupTrace("ordered front");if !automatedTesting {NSApp.activate(ignoringOtherApps:true)};startupTrace("activated")
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded();startupTrace("displayed")
        let ms=Double(DispatchTime.now().uptimeNanoseconds-lumenStart)/1_000_000
        if let path=ProcessInfo.processInfo.environment["LUMEN_BENCHMARK_FILE"] {
            try? "\(ms)\n".write(toFile:path,atomically:true,encoding:.utf8)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { NSApp.terminate(nil) }
        }
        if ProcessInfo.processInfo.arguments.contains("--revision-tests") {Task{await self.runRevisionTests()};return}
        if ProcessInfo.processInfo.arguments.contains("--self-test") { DispatchQueue.main.async { self.runEditorSelfTests() }; return }
        DispatchQueue.main.async { [weak self] in
            guard let self else{return}
            self.populateLanguages()
            if !self.pendingURLs.isEmpty { self.pendingURLs.forEach { self.openURL($0) }; self.pendingURLs=[];self.offerFirstLaunchSetup() }
            else if self.suppressSessionRestore {self.offerFirstLaunchSetup()}
            else if ProcessInfo.processInfo.environment["LUMEN_BENCHMARK_FILE"] == nil { self.restoreSession() }
        }
    }
    func buildWindow() {
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.tabbingMode = .disallowed;window.title="Orkhon Code"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent=true
        window.minSize=NSSize(width:720,height:440); window.center()
        if automatedTesting {window.alphaValue=0;window.ignoresMouseEvents=true}
        else {window.setFrameAutosaveName("OrkhonEditor.MainWindow")}
        window.delegate=self
        window.contentView=root; root.addSubview(header); root.addSubview(tabsSurface);root.addSubview(statusSurface)
        let treeVC=NSViewController();treeVC.view=treeHost
        treeItem=NSSplitViewItem(sidebarWithViewController:treeVC);treeItem.minimumThickness=210;treeItem.preferredThicknessFraction=0.22;treeItem.maximumThickness=480;treeItem.canCollapse=true;treeItem.isCollapsed=true
        mainSplit.addSplitViewItem(treeItem)
        let workVC=NSViewController();workVC.view=editorSurface
        workSplit.splitView.isVertical=false
        let editingItem=NSSplitViewItem(viewController:workVC);editingItem.minimumThickness=150
        workSplit.addSplitViewItem(editingItem)
        let terminalVC=NSViewController();terminalVC.view=terminalHost
        terminalItem=NSSplitViewItem(viewController:terminalVC);terminalItem.canCollapse=true;terminalItem.minimumThickness=130;terminalItem.isCollapsed=true
        workSplit.addSplitViewItem(terminalItem)
        let workspaceItem=NSSplitViewItem(viewController:workSplit);workspaceItem.minimumThickness=480
        mainSplit.addSplitViewItem(workspaceItem);root.addSubview(mainSplit.view)
        let sidebar=iconButton("sidebar.left","Toggle Files  ⌘B",target:self,action:#selector(toggleSidebar(_:)))
        sidebar.frame.origin=NSPoint(x:10,y:6);tabsSurface.addSubview(sidebar)
        let open=iconButton("doc.badge.plus","Open File  ⌘O",target:self,action:#selector(openFile(_:)))
        open.frame.origin=NSPoint(x:46,y:6);tabsSurface.addSubview(open)
        brand.frame=NSRect(x:90,y:12,width:114,height:20);header.addSubview(brand)
        pathLabel.font = .systemFont(ofSize:12);pathLabel.lineBreakMode = .byTruncatingMiddle;header.addSubview(pathLabel)
        themePicker.title=theme.name;themePicker.image=NSImage(systemSymbolName:"paintpalette",accessibilityDescription:nil);themePicker.imagePosition = .imageLeading;themePicker.font = .systemFont(ofSize:12);themePicker.target=self;themePicker.action=#selector(changeTheme(_:));themePicker.isBordered=false;themePicker.toolTip="Color theme";header.addSubview(themePicker)
        let folder=iconButton("folder","Open Folder  ⇧⌘O",target:self,action:#selector(openFolder(_:)));folder.frame.origin=NSPoint(x:82,y:6);tabsSurface.addSubview(folder)
        let ssh=iconButton("network","Connect over SSH",target:self,action:#selector(connectRemote(_:)));ssh.frame.origin=NSPoint(x:118,y:6);tabsSurface.addSubview(ssh)
        let term=iconButton("terminal","Toggle Terminal  ⌃`",target:self,action:#selector(toggleTerminal(_:)));term.identifier=NSUserInterfaceItemIdentifier("terminalButton");tabsSurface.addSubview(term)
        tabScroll.onScroll = { [weak self] in self?.updateTabOverflow() };tabsSurface.addSubview(tabScroll)
        for (button,symbol,action) in [(tabBack,"chevron.left",#selector(scrollTabsBack(_:))),(tabForward,"chevron.right",#selector(scrollTabsForward(_:))),(allTabs,"list.bullet",#selector(listTabs(_:)))] {button.isBordered=false;button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);button.target=self;button.action=action;tabsSurface.addSubview(button)}
        tabBack.setAccessibilityLabel("Scroll tabs left");tabForward.setAccessibilityLabel("Scroll tabs right");allTabs.setAccessibilityLabel("All open tabs");allTabs.imagePosition = .imageLeading
        tabStack.orientation = .horizontal;tabStack.alignment = .centerY;tabStack.spacing=2;tabScroll.documentView=tabStack
        let plus=iconButton("plus","New Tab  ⌘N",target:self,action:#selector(newDocument(_:)));tabsSurface.addSubview(plus)
        status.font = .monospacedSystemFont(ofSize:11,weight:.regular);statusSurface.addSubview(status)
        languagePicker.isBordered=false;languagePicker.font = .systemFont(ofSize:11);languagePicker.title="Plain Text";languagePicker.image=NSImage(systemSymbolName:"chevron.up.chevron.down",accessibilityDescription:nil);languagePicker.imagePosition = .imageTrailing;languagePicker.setAccessibilityLabel("Choose syntax language");languagePicker.target=self;languagePicker.action=#selector(changeLanguage(_:));statusSurface.addSubview(languagePicker)
        editorSplit.addArrangedSubview(firstPane);editorSplit.addArrangedSubview(secondPane);secondPane.isHidden=true;editorSurface.addSubview(editorSplit)
        editorSurface.addSubview(externalBar);externalBar.addSubview(externalLabel);externalBar.addSubview(externalButton);externalLabel.font = .systemFont(ofSize:12);externalButton.font = .systemFont(ofSize:11,weight:.medium);externalButton.target=self;externalButton.action=#selector(reviewExternalChange(_:))
        buildFindBar()
        root.onLayout = { [weak self] in
            guard let self else{return};let b=self.root.bounds
            self.header.frame=NSRect(x:0,y:b.height-36,width:b.width,height:36)
            self.tabsSurface.frame=NSRect(x:0,y:b.height-78,width:b.width,height:42)
            self.statusSurface.frame=NSRect(x:0,y:0,width:b.width,height:27)
            self.mainSplit.view.frame=NSRect(x:0,y:27,width:b.width,height:max(100,b.height-105))
            self.pathLabel.frame=NSRect(x:220,y:13,width:max(40,b.width-386),height:18)
            self.themePicker.frame=NSRect(x:b.width-150,y:8,width:135,height:24)
            term.frame=NSRect(x:b.width-42,y:6,width:32,height:30)
            self.tabScroll.frame=NSRect(x:154,y:2,width:max(100,b.width-344),height:38);plus.frame=NSRect(x:b.width-78,y:6,width:30,height:30)
            self.tabBack.frame=NSRect(x:b.width-188,y:9,width:22,height:24);self.tabForward.frame=NSRect(x:b.width-165,y:9,width:22,height:24);self.allTabs.frame=NSRect(x:b.width-139,y:8,width:57,height:26);self.updateTabOverflow()
            self.status.frame=NSRect(x:16,y:5,width:max(200,b.width-225),height:17)
            self.languagePicker.frame=NSRect(x:b.width-200,y:2,width:185,height:24)
        }
        editorSurface.onLayout = { [weak self] in self?.layoutEditor() }
        applyTheme()
    }
    func layoutEditor() {
        let b=editorSurface.bounds;let h:CGFloat=showFind ? 100:0
        let externalHeight:CGFloat=current?.externalChange != nil ? 38:0
        externalBar.isHidden=externalHeight==0;externalBar.frame=NSRect(x:0,y:b.height-h-externalHeight,width:b.width,height:externalHeight)
        externalLabel.stringValue=current?.externalChange?.merge.map{_ in "\(current?.externalChange?.remainingConflicts ?? 0) unresolved conflict\((current?.externalChange?.remainingConflicts ?? 0)==1 ? "":"s")"} ?? "External changes · review needed";externalLabel.frame=NSRect(x:14,y:10,width:max(120,b.width-176),height:18)
        externalButton.title=current?.externalChange?.merge == nil ? "Save a copy…":"Next conflict"
        externalLabel.toolTip=current?.externalChange?.error
        externalButton.frame=NSRect(x:b.width-152,y:5,width:138,height:28)
        findBar.frame=NSRect(x:0,y:b.height-h,width:b.width,height:h);findBar.isHidden = !showFind
        editorSplit.frame=NSRect(x:0,y:0,width:b.width,height:max(0,b.height-h-externalHeight));layoutEditorPanes();firstPane.needsLayout=true;secondPane.needsLayout=true;editorSplit.layoutSubtreeIfNeeded()
        let inputWidth=max(170,b.width-258)
        findInput.frame=NSRect(x:14,y:h-43,width:inputWidth,height:32)
        findField.frame=NSRect(x:29,y:0,width:inputWidth-39,height:32)
        let x=14+inputWidth+10
        caseToggle.frame=NSRect(x:x,y:h-42,width:30,height:30)
        wordToggle.frame=NSRect(x:x+34,y:h-42,width:30,height:30)
        regexToggle.frame=NSRect(x:x+68,y:h-42,width:30,height:30)
        for (i,tag) in [10,11,12].enumerated() { findBar.viewWithTag(tag)?.frame=NSRect(x:b.width-112+CGFloat(i)*34,y:h-42,width:30,height:30) }
        replaceInput.frame=NSRect(x:14,y:19,width:inputWidth,height:32)
        replaceField.frame=NSRect(x:10,y:0,width:inputWidth-20,height:32)
        findBar.viewWithTag(13)?.frame=NSRect(x:x,y:19,width:88,height:32)
        findBar.viewWithTag(14)?.frame=NSRect(x:x+96,y:19,width:110,height:32)
        findResult.frame=NSRect(x:18,y:2,width:b.width-36,height:15)
        replaceInput.isHidden = !showReplace;findBar.viewWithTag(13)?.isHidden = !showReplace;findBar.viewWithTag(14)?.isHidden = !showReplace
    }
    func buildFindBar() {
        editorSurface.addSubview(findBar)
        for input in [findInput,replaceInput] { input.wantsLayer=true;input.layer?.cornerRadius=7;input.layer?.borderWidth=1;findBar.addSubview(input) }
        findField.placeholderString="Find in document";findField.target=self;findField.action=#selector(findNext(_:));findField.delegate=self
        findField.isBordered=false;findField.isBezeled=false;findField.drawsBackground=false;findField.focusRingType = .none;findField.font = .systemFont(ofSize:13);findField.setAccessibilityLabel("Find in document");findInput.addSubview(findField)
        let searchIcon=NSImageView(image:NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:nil)!);searchIcon.contentTintColor = .secondaryLabelColor;searchIcon.frame=NSRect(x:10,y:9,width:14,height:14);findInput.addSubview(searchIcon)
        replaceField.placeholderString="Replace with";replaceField.isBordered=false;replaceField.isBezeled=false;replaceField.drawsBackground=false;replaceField.focusRingType = .none;replaceField.font = .systemFont(ofSize:13);replaceField.delegate=self;replaceField.setAccessibilityLabel("Replace with");replaceInput.addSubview(replaceField)
        for t in [caseToggle,regexToggle,wordToggle] { t.setButtonType(.toggle);t.font = .monospacedSystemFont(ofSize:12,weight:.medium);findBar.addSubview(t) }
        caseToggle.toolTip="Match case";caseToggle.setAccessibilityLabel("Match case")
        regexToggle.toolTip="Use regular expression";regexToggle.setAccessibilityLabel("Use regular expression")
        wordToggle.toolTip="Match whole word";wordToggle.setAccessibilityLabel("Match whole word")
        let prev=iconButton("chevron.up","Previous match  ⇧⌘G",target:self,action:#selector(findPrevious(_:)));prev.tag=10
        let next=iconButton("chevron.down","Next match  ⌘G",target:self,action:#selector(findNext(_:)));next.tag=11
        let close=iconButton("xmark","Close Find  Escape",target:self,action:#selector(closeFind(_:)));close.tag=12
        for b in [prev,next,close] {findBar.addSubview(b)}
        let replace=PillButton(title:"Replace",target:self,action:#selector(replaceOne(_:)));replace.tag=13;findBar.addSubview(replace)
        let all=PillButton(title:"Replace all",target:self,action:#selector(replaceAll(_:)));all.tag=14;findBar.addSubview(all)
        findResult.font = .systemFont(ofSize:10);findBar.addSubview(findResult)
    }
    func applyTheme() {
        window?.appearance=NSAppearance(named:theme.dark ? .darkAqua:.aqua)
        window?.backgroundColor=theme.background
        root.color(theme.background);header.color(theme.panelColor);tabsSurface.color(theme.panelColor);statusSurface.color(theme.panelColor);findBar.color(theme.panelColor);editorSurface.color(theme.background)
        for input in [findInput,replaceInput] { input.color(theme.background);input.layer?.borderColor=NSColor(hex:theme.muted).withAlphaComponent(0.22).cgColor }
        for button in findBar.subviews.compactMap({$0 as? PillButton}) { button.accent=theme.accentColor;button.foreground=theme.foreground;button.needsDisplay=true }
        findField.textColor=theme.foreground;replaceField.textColor=theme.foreground;findResult.textColor=NSColor(hex:theme.muted)
        externalBar.color(theme.accentColor.withAlphaComponent(0.1));externalLabel.textColor=theme.foreground;externalButton.accent=theme.accentColor;externalButton.foreground=theme.foreground
        tabScroll.accent=theme.accentColor
        brand.textColor=theme.accentColor;pathLabel.textColor=NSColor(hex:theme.muted);status.textColor=NSColor(hex:theme.muted)
        firstPane.updatePreview();if editorIsSplit {secondPane.updatePreview()};remoteTree?.applyTheme(theme)
        tree?.applyTheme(background:theme.panelColor,foreground:theme.foreground,accent:theme.accentColor)
        terminal?.applyTheme(background:theme.background,foreground:theme.foreground,accent:theme.accentColor)
        documents.forEach { $0.editor.applyPalette(theme.palette) };rebuildTabs()
    }
    @objc func changeTheme(_ sender:Any?) {
        themeWindow=CommandPalette(parent:window,title:"Color theme",placeholder:"Choose a theme…",items:Theme.all.enumerated().map{PaletteItem(title:$0.element.name,subtitle:$0.element.dark ? "Dark":"Light",shortcut:$0.element.name==theme.name ? "✓":"",identifier:String($0.offset))},compact:true) { [weak self] item in if let index=Int(item.identifier) {self?.chooseTheme(index)} }
        themeWindow?.present()
    }
    func chooseTheme(_ index:Int) {guard Theme.all.indices.contains(index) else{return};theme=Theme.all[index];themePicker.title=theme.name;UserDefaults.standard.set(index,forKey:"theme");applyTheme()}
    @objc func selectThemeMenu(_ sender:NSMenuItem) {chooseTheme(sender.tag)}
    func populateLanguages() { updateStatus() }
    @objc func changeLanguage(_ sender:Any?) {
        guard let document=current else{return}
        languageWindow?.close()
        var items=[PaletteItem(title:"Automatic",subtitle:"Detect from filename or script header",shortcut:document.languageOverride ? "":"✓",identifier:"auto"),PaletteItem(title:"Plain Text",subtitle:"No syntax highlighting",shortcut:document.language == nil && document.languageOverride ? "✓":"",identifier:"plain")]
        items += LanguageRegistry.shared.languages.map { PaletteItem(title:$0.name,subtitle:$0.extensions.prefix(6).map{"."+$0}.joined(separator:"  "),shortcut:document.language?.name == $0.name ? "✓":"",identifier:$0.name) }
        languageWindow=CommandPalette(parent:window,title:"Syntax language",placeholder:"Search languages or extensions…",items:items,compact:true) { [weak self,weak document] item in
            guard let self,let document,self.documents.contains(where:{$0 === document}) else{return}
            document.languageOverride=item.identifier != "auto"
            if item.identifier == "auto" { document.language=LanguageRegistry.shared.language(for:document.url ?? document.remotePath.map{URL(fileURLWithPath:$0)},text:String(document.editor.text.prefix(2048))) }
            else { document.language=LanguageRegistry.shared.languages.first{$0.name == item.identifier} }
            self.configureLanguage(document);self.updateStatus();self.updateMarkdownPreview()
        }
        languageWindow?.present()
    }
    func configureLanguage(_ d:DocumentTab) {
        if let l=d.language { d.editor.setLexer(l.lexer,keywords:l.keywords,properties:l.properties) }
        else { d.editor.setLexer("null",keywords:[],properties:[:]) }
        d.editor.applyPalette(theme.palette)
    }
    @objc func newDocument(_ sender:Any?) {
        let d=DocumentTab();documents.append(d);configureEditor(d);selectDocument(documents.count-1)
    }
    func configureEditor(_ d:DocumentTab) {
        d.editor.wordWrap=wrap;d.editor.showWhitespace=whitespace;d.editor.fontSize=fontSize;d.editor.send(2031,w:2,l:0)
        d.editor.tabWidth=UserDefaults.standard.integer(forKey:"tabWidth");d.editor.useTabs = !UserDefaults.standard.bool(forKey:"spaces")
        d.editor.applyPalette(theme.palette)
        d.editor.onChange = { [weak self,weak d] in guard let self,let d,!d.loading else{return};if d.displayedDirty != d.isModified {self.rebuildTabs()};self.updateStatus();self.scheduleRecovery(d);self.pane(for:d)?.schedulePreview();if let change=d.externalChange,change.localText != d.editor.text {self.scheduleExternalCheck()} }
        d.editor.onUpdate = { [weak self,weak d] in guard let self,let d else{return};if d.editor.send(2381,w:0,l:0) != 0 {self.focusDocument(d)};self.updateStatus();self.pane(for:d)?.externalControls?.needsLayout=true }
    }
    func selectDocument(_ index:Int) {
        guard documents.indices.contains(index) else{return}
        let target=documents[index],pane=activePane
        if firstPane.document === target {selected=index;firstPane.updatePreview()}
        else if editorIsSplit && secondPane.document === target {selected=index;secondPane.updatePreview()}
        else {selected=index;pane.bind(target,owner:self)}
        layoutEditor();target.editor.focus();terminal?.workingDirectory=workspaceURL ?? target.url?.deletingLastPathComponent();rebuildTabs();revealSelectedTab();updateStatus();updateAutomaticWorkspace()
    }

    @objc func selectTab(_ sender:NSButton) {selectDocument(sender.tag)}
    func rebuildTabs() {
        guard window != nil else{return}
        tabStack.arrangedSubviews.forEach {tabStack.removeArrangedSubview($0);$0.removeFromSuperview()}
        var total:CGFloat=0
        for (index,d) in documents.enumerated() {
            d.displayedDirty=d.isModified
            let holder=Surface(frame:NSRect(x:0,y:0,width:172,height:33));holder.color(theme.accentColor.withAlphaComponent(index==selected ? 0.19:0.045));holder.layer?.cornerRadius=6;holder.layer?.borderWidth=1;holder.layer?.borderColor=theme.accentColor.withAlphaComponent(index==selected ? 0.8:0.23).cgColor
            let button=DocumentTabButton(title:(d.pinned ? "⌖  ":"")+(d.isModified ? "●  ":"")+d.title,target:self,action:#selector(selectTab(_:)));button.isBordered=false;button.alignment = .left;button.font = .systemFont(ofSize:12,weight:index==selected ? .medium:.regular);button.lineBreakMode = .byTruncatingMiddle;button.tag=index;button.contentTintColor=index==selected ? theme.accentColor:theme.foreground.withAlphaComponent(0.75);button.frame=NSRect(x:9,y:2,width:132,height:29);button.toolTip=d.url?.path ?? "Unsaved document";button.documentID=d.id;button.contextMenu = { [weak self,weak d] in guard let self,let d else{return NSMenu()};return self.tabMenu(for:d) };holder.addSubview(button)
            let close=iconButton("xmark","Close \(d.title)",target:self,action:#selector(closeTabButton(_:)));close.tag=index;close.frame=NSRect(x:143,y:4,width:24,height:25);holder.addSubview(close)
            holder.translatesAutoresizingMaskIntoConstraints=false;holder.widthAnchor.constraint(equalToConstant:172).isActive=true;holder.heightAnchor.constraint(equalToConstant:33).isActive=true;tabStack.addArrangedSubview(holder);total+=174
        }
        tabStack.frame=NSRect(x:0,y:0,width:total,height:33);tabStack.layoutSubtreeIfNeeded();updateTabOverflow()
    }
    func updateStatus() {
        guard let d=current else{return}
        for pane in [firstPane,secondPane] {if let doc=pane.document {pane.title.stringValue=(doc.isModified ? "●  ":"")+doc.title}}
        window.isDocumentEdited=d.isModified;window.title="\(d.title) — Orkhon Code";window.representedURL=d.url
        pathLabel.stringValue=d.isWelcome ? "Welcome" : d.remotePath.map{ "\(remote?.host ?? "SSH"):\($0)" } ?? d.url?.abbreviatingWithTildeInPath ?? "new document: here is a little room to think."
        let e=d.format.map { String.localizedName(of:$0.encoding) } ?? "UTF-8"
        let ending=d.format?.lineEnding == "\r\n" ? "CRLF":(d.format?.lineEnding == "\r" ? "CR":"LF")
        status.stringValue="Ln \(d.editor.currentLine), Col \(d.editor.currentColumn)    \(d.editor.selectionLength>0 ? "\(d.editor.selectionLength) selected    ":"")\(e)    \(ending)    \(d.editor.useTabs ? "Tabs":"Spaces"): \(d.editor.tabWidth)"
        languagePicker.title=d.language?.name ?? "Plain Text"
    }
    @objc func openFile(_ sender:Any?) {
        let p=NSOpenPanel();p.allowsMultipleSelection=true;p.canChooseDirectories=false
        p.beginSheetModal(for:window) { [weak self] result in if result == .OK { p.urls.forEach {self?.openURL($0)} } }
    }
    @objc func openFolder(_ sender:Any?) {
        let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;p.prompt="Open Folder"
        p.beginSheetModal(for:window) { [weak self] result in guard result == .OK,let url=p.url else{return};self?.setFolder(url) }
    }
    func ensureTree() {
        if remote != nil {ensureRemoteTree();return}
        guard tree == nil else{return}
        let t=FileTreePanel(frame:treeHost.bounds);t.autoresizingMask=[.width,.height];treeHost.addSubview(t);tree=t
        t.onOpenFile = { [weak self] in self?.openURL($0) };t.onOpenFileInNewWindow = { [weak self] url in self?.coordinator?.newWindow().openURL(url) };t.onChooseFolder = { [weak self] in self?.openFolder(nil) }
        t.onMove = { [weak self] old,new in self?.reconcileMovedFiles(from:old,to:new) }
        t.onTrash = { [weak self] url in self?.reconcileTrashedFiles(url) }
        t.applyTheme(background:theme.panelColor,foreground:theme.foreground,accent:theme.accentColor)
        if let workspaceURL {t.setRoot(workspaceURL)};updateTreeOpenFiles()
    }
    func setFolder(_ url:URL) {
        if remote != nil {disconnectRemote(nil);guard remote == nil else{return}}
        manualWorkspace=true;workspaceURL=url;ensureTree();tree?.setRoot(url);updateTreeOpenFiles();treeItem.isCollapsed=false;terminal?.workingDirectory=url;persistSession()
    }
    func openURL(_ raw:URL, fallbackEncoding:String.Encoding? = nil) {
        let url=raw.standardizedFileURL.resolvingSymlinksInPath()
        var isDir:ObjCBool=false
        if FileManager.default.fileExists(atPath:url.path,isDirectory:&isDir),isDir.boolValue {setFolder(url);return}
        if let index=documents.firstIndex(where:{$0.url == url}) { selectDocument(index);return }
        let d=DocumentTab();d.url=url;d.loading=true;d.editor.send(2171,w:1,l:0)
        if documents.count==1,let first=documents.first,first.url==nil,!first.isModified,first.editor.text.isEmpty {first.editor.removeFromSuperview();documents=[];selected = -1}
        documents.append(d);configureEditor(d);selectDocument(documents.count-1);status.stringValue="Opening \(url.lastPathComponent)…"
        ioQueue.async { [weak self,weak d] in
            let result=Result {try DocumentStorage.read(url,fallbackEncoding:fallbackEncoding)}
            DispatchQueue.main.async {
                guard let self,let d,self.documents.contains(where:{$0 === d}) else{return}
                switch result {
                case .success(let file):
                    d.format=file;d.editor.send(2171,w:0,l:0);d.editor.text=file.text;d.editor.send(2031,w:file.lineEnding == "\r\n" ? 0:(file.lineEnding == "\r" ? 1:2),l:0);d.editor.markSaved();d.loading=false
                    d.language=LanguageRegistry.shared.language(for:url,text:String(file.text.prefix(200)))
                    self.configureLanguage(d);self.updateStatus();self.rebuildTabs();self.revealSelectedTab();self.updateAutomaticWorkspace();self.pane(for:d)?.updatePreview();self.persistSession()
                    if ProcessInfo.processInfo.environment["ORKHON_TEST_DATA"] == nil {NSDocumentController.shared.noteNewRecentDocumentURL(url)};self.refreshRecents()
                case .failure(let error):d.loading=false;self.showError(error);self.removeDocument(d)
                }
            }
        }
    }
    func application(_ sender:NSApplication,open urls:[URL]) {if launched {urls.forEach {openURL($0)};bringToFront();DispatchQueue.main.async {self.bringToFront()} } else {pendingURLs+=urls}}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {bringToFront();return true}
    @objc func save(_ sender:Any?) {guard let d=current else{return};_ = saveDocument(d,asNew:false)}
    @objc func saveAs(_ sender:Any?) {guard let d=current else{return};_ = saveDocument(d,asNew:true)}
    @discardableResult func saveDocument(_ d:DocumentTab,asNew:Bool)->Bool {
        guard !d.loading else{return false}
        if d.externalChange != nil && !asNew {selectDocument(documents.firstIndex(where:{$0===d}) ?? selected);reviewExternalChange(nil);return false}
        if d.remotePath != nil && !asNew {return saveRemoteDocument(d)}
        var url=d.isWelcome ? nil : d.url
        if url==nil || asNew {
            let p=NSSavePanel();p.nameFieldStringValue=d.url?.lastPathComponent ?? "Untitled.txt";p.directoryURL=d.url?.deletingLastPathComponent() ?? workspaceURL
            guard p.runModal() == .OK,let chosen=p.url else{return false};url=chosen
        }
        guard let destination=url else{return false}
        do {
            let same=destination.standardizedFileURL == d.url?.standardizedFileURL
            d.format=try DocumentStorage.write(text:d.editor.text,to:destination,format:d.format,expected:same ? d.format?.originalData:nil)
            d.url=destination;d.isWelcome=false;d.remotePath=nil;d.baselineChanged=false;d.externalChange=nil;d.externalHighlights=nil;d.externalAnchors=[];d.editor.clearExternalAnnotations();for marker in [24,25,26] {d.editor.send(2045,w:marker,l:0)};d.editor.markSaved();pane(for:d)?.updatePreview();updateAutomaticWorkspace()
            if !d.languageOverride {d.language=LanguageRegistry.shared.language(for:destination,text:String(d.editor.text.prefix(200)));configureLanguage(d)}
            clearRecovery(d);rebuildTabs();updateStatus();persistSession();tree?.refresh();if ProcessInfo.processInfo.environment["ORKHON_TEST_DATA"] == nil {NSDocumentController.shared.noteNewRecentDocumentURL(destination)};refreshRecents();return true
        } catch DocumentStorageError.externalChange {requestExternalReview(d);return false}
        catch {showError(error);return false}
    }
    @objc func saveAll(_ sender:Any?) {for d in documents where d.isModified {if !saveDocument(d,asNew:false){break}}}
    @objc func revert(_ sender:Any?) {
        guard let d=current,let url=d.url else{return}
        let a=NSAlert();a.messageText="Reload \(d.title) from disk?";a.informativeText="Edits in this tab will be discarded.";a.addButton(withTitle:"Reload");a.addButton(withTitle:"Cancel")
        guard a.runModal() == .alertFirstButtonReturn else{return}
        do {let file=try DocumentStorage.read(url);d.loading=true;d.format=file;d.editor.send(2171,w:0,l:0);d.editor.text=file.text;d.editor.send(2031,w:file.lineEnding == "\r\n" ? 0:(file.lineEnding == "\r" ? 1:2),l:0);d.editor.markSaved();d.loading=false;clearRecovery(d);rebuildTabs();updateStatus()}catch{showError(error)}
    }
    func confirmClose(_ d:DocumentTab)->Bool {
        guard d.isModified else{return true}
        let a=NSAlert();a.messageText="Save changes to \(d.title)?";a.informativeText="Your changes will be lost if you don’t save them.";a.addButton(withTitle:"Save");a.addButton(withTitle:"Cancel");a.addButton(withTitle:"Don’t Save")
        switch a.runModal() {case .alertFirstButtonReturn:return saveDocument(d,asNew:false);case .alertThirdButtonReturn:return true;default:return false}
    }
    @objc func closeCurrent(_ sender:Any?) {guard let d=current,confirmClose(d) else{return};removeDocument(d)}
    @objc func closeTabButton(_ sender:NSButton) {guard documents.indices.contains(sender.tag) else{return};let d=documents[sender.tag];if confirmClose(d){removeDocument(d)}}
    func removeDocument(_ d:DocumentTab) {
        guard let index=documents.firstIndex(where:{$0 === d}) else{return}
        if editorIsSplit && (firstPane.document === d || secondPane.document === d) {collapseEditorSplit(keeping:firstPane.document === d ? secondPane.document:firstPane.document)}
        let active=current;d.editor.removeFromSuperview();clearRecovery(d);documents.remove(at:index)
        if documents.isEmpty {selected = -1;newDocument(nil)}
        else if let active,active !== d,let same=documents.firstIndex(where:{$0 === active}) {selected=same;rebuildTabs()}
        else {selected = -1;selectDocument(min(index,documents.count-1))}
        updateAutomaticWorkspace();persistSession()
    }
    func window(_ window:NSWindow,willUseStandardFrame newFrame:NSRect)->NSRect {window.screen?.visibleFrame ?? newFrame}
    func windowDidBecomeMain(_ notification:Notification) {buildMenus();checkExternalChanges()}
    func canClose(terminating:Bool)->Bool {
        for d in documents {if !confirmClose(d){return false}}
        if terminal?.hasRunningSessions == true {
            let a=NSAlert();a.messageText=terminating ? "Quit and close this window’s terminals?":"Close this window and its terminals?"
            a.informativeText="Running terminal processes will receive a hangup signal."
            a.addButton(withTitle:terminating ? "Quit":"Close Window");a.addButton(withTitle:"Cancel")
            if a.runModal() != .alertFirstButtonReturn {return false}
        }
        return true
    }
    func finishClosing() {
        sshWindow?.cancelPendingConnection();sshWindow=nil;externalCheck?.cancel();localWorkspaceRefresh.cancel();remoteWorkspaceRefresh.cancel();fileMonitor.stop();remoteMonitor.stop();remotePollTimer?.invalidate();remotePollTimer=nil
        documents.forEach{clearRecovery($0)};terminal?.terminateAll()
        coordinator?.releaseConnection(for:self);recoveryQueue.sync {}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard canClose(terminating:false) else{return false}
        finishClosing();coordinator?.removeWindow(self);return true
    }
    func applicationDidBecomeActive(_ notification:Notification) {guard launched else{return};tree?.refresh();checkExternalChanges()}
    @objc func toggleSidebar(_ sender:Any?) {
        if treeItem.isCollapsed {ensureTree()};treeItem.isCollapsed.toggle()
        if !treeItem.isCollapsed {
            if remote != nil,remoteTreeDirty {remoteTree?.refreshPreservingState();remoteTreeDirty=false}
            else if remote==nil,localTreeDirty {tree?.refresh();localTreeDirty=false}
        }
    }
    @objc func toggleTerminal(_ sender:Any?) {
        if terminal == nil {
            let t=TerminalPanel(frame:terminalHost.bounds);t.autoresizingMask=[.width,.height];t.workingDirectory=workspaceURL ?? current?.url?.deletingLastPathComponent();t.remoteWorkspace=remote;terminalHost.addSubview(t);terminal=t;t.applyTheme(background:theme.background,foreground:theme.foreground,accent:theme.accentColor)
        }
        terminal?.workingDirectory=workspaceURL ?? current?.url?.deletingLastPathComponent()
        terminalItem.isCollapsed.toggle()
        if !terminalItem.isCollapsed {workSplit.splitView.setPosition(max(160,workSplit.view.bounds.height-240),ofDividerAt:0);terminal?.ensureSession()}
        else {current?.editor.focus()}
    }
    @objc func expandTerminal(_ sender:Any?) {if terminalItem.isCollapsed {toggleTerminal(nil)};workSplit.splitView.setPosition(160,ofDividerAt:0)}
    @objc func toggleWrap(_ sender:Any?) {wrap.toggle();UserDefaults.standard.set(wrap,forKey:"wordWrap");documents.forEach {$0.editor.wordWrap=wrap}}
    @objc func toggleWhitespace(_ sender:Any?) {whitespace.toggle();documents.forEach {$0.editor.showWhitespace=whitespace}}
    @objc func zoomIn(_ sender:Any?) {fontSize=min(28,fontSize+1);documents.forEach {$0.editor.fontSize=fontSize}}
    @objc func zoomOut(_ sender:Any?) {fontSize=max(10,fontSize-1);documents.forEach {$0.editor.fontSize=fontSize}}
    @objc func zoomReset(_ sender:Any?) {fontSize=14;documents.forEach {$0.editor.fontSize=fontSize}}
    @objc func setIndent(_ sender:NSMenuItem) {UserDefaults.standard.set(sender.tag,forKey:"tabWidth");documents.forEach {$0.editor.tabWidth=sender.tag};updateStatus()}
    @objc func toggleTabs(_ sender:Any?) {let tabs = !(current?.editor.useTabs ?? false);UserDefaults.standard.set(!tabs,forKey:"spaces");documents.forEach {$0.editor.useTabs=tabs};updateStatus()}
    @objc func nextTab(_ sender:Any?) {if !documents.isEmpty {selectDocument((selected+1)%documents.count)}}
    @objc func previousTab(_ sender:Any?) {if !documents.isEmpty {selectDocument((selected+documents.count-1)%documents.count)}}
    @objc func showFind(_ sender:Any?) {showFind=true;showReplace=true;current?.previewingMarkdown=false;updateMarkdownPreview();layoutEditor();window.makeFirstResponder(findField)}
    @objc func showReplace(_ sender:Any?) {showFind=true;showReplace=true;current?.previewingMarkdown=false;updateMarkdownPreview();layoutEditor();window.makeFirstResponder(findField)}
    @objc func closeFind(_ sender:Any?) {showFind=false;layoutEditor();current?.editor.focus()}
    func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {if commandSelector == #selector(NSResponder.cancelOperation(_:)) {closeFind(nil);return true};return false}
    @objc func findNext(_ sender:Any?) {performFind(false)}
    @objc func findPrevious(_ sender:Any?) {performFind(true)}
    func performFind(_ backwards:Bool) {
        guard !findField.stringValue.isEmpty else{showFind(nil);return}
        let ok=current?.editor.find(findField.stringValue,backwards:backwards,matchCase:caseToggle.state == .on,regex:regexToggle.state == .on,wholeWord:wordToggle.state == .on) ?? false
        findField.textColor=ok ? theme.foreground:.systemRed
        findResult.stringValue=ok ? "Match found":"No match"
    }
    @objc func replaceOne(_ sender:Any?) {performReplace(false)}
    @objc func replaceAll(_ sender:Any?) {performReplace(true)}
    func performReplace(_ all:Bool) {
        guard !findField.stringValue.isEmpty else{return}
        let n=current?.editor.replace(findField.stringValue,with:replaceField.stringValue,all:all,matchCase:caseToggle.state == .on,regex:regexToggle.state == .on,wholeWord:wordToggle.state == .on) ?? 0
        findResult.stringValue=n<0 ? "Invalid expression":"\(n) replaced"
    }
    @objc func goToLine(_ sender:Any?) {
        let a=NSAlert();a.messageText="Go to line";let f=NSTextField(frame:NSRect(x:0,y:0,width:260,height:26));f.placeholderString="Line number";a.accessoryView=f;a.addButton(withTitle:"Go");a.addButton(withTitle:"Cancel");a.window.initialFirstResponder=f
        if a.runModal() == .alertFirstButtonReturn,let line=Int(f.stringValue),line>0 {current?.editor.go(toLine:line);current?.editor.focus()}
    }
    @objc func editorCommand(_ sender:NSMenuItem) {current?.editor.command(sender.tag)}
    var lineCommentPrefix:String? {
        switch current?.language?.lexer ?? "" {
        case "python","bash","ruby","perl","r","yaml","toml","makefile","props","powershell","julia","cmake","coffeescript","conf": return "#"
        case "sql","lua","haskell","ada","vhdl": return "--"
        case "cpp","cppnocase","rust","d","dart","go","java","kotlin","swift","groovy","pascal","asymptote","zig": return "//"
        case "lisp","asm","inno": return ";"
        case "matlab","octave","latex","tex": return "%"
        case "fortran","f77": return "!"
        case "vb","vbscript": return "'"
        case "batch": return "REM"
        default: return nil
        }
    }
    @objc func toggleComment(_ sender:Any?) {
        guard let prefix=lineCommentPrefix else {status.stringValue="Line comments are not available for this language.";return}
        current?.editor.toggleComment(prefix)
    }
    @objc func printDocument(_ sender:Any?) {
        guard let d=current else{return};let text=NSTextView(frame:NSRect(x:0,y:0,width:540,height:720));text.string=d.editor.text;text.font = .monospacedSystemFont(ofSize:11,weight:.regular);text.isHorizontallyResizable=false;text.isVerticallyResizable=true;text.maxSize=NSSize(width:540,height:CGFloat.greatestFiniteMagnitude);text.textContainer?.widthTracksTextView=true;text.textContainer?.containerSize=NSSize(width:540,height:CGFloat.greatestFiniteMagnitude);text.sizeToFit()
        let info=NSPrintInfo.shared.copy() as! NSPrintInfo;info.horizontalPagination = .fit;info.isVerticallyCentered=false
        NSPrintOperation(view:text,printInfo:info).run()
    }
    func showError(_ error:Error) {let a=NSAlert(error:error);a.runModal()}
    @objc func about(_ sender:Any?) {NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Orkhon Code",.applicationVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.5.0",.version:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "8",.credits:NSAttributedString(string:"A small, native place for text.\n\nEditing: Scintilla · Syntax: Lexilla\nTerminal: SwiftTerm\nOpen-source licenses included in the app.")])}
    @objc func help(_ sender:Any?) {if let url=Bundle.main.url(forResource:"User Guide",withExtension:"md"){openURL(url)}}
    @objc func quickOpen(_ sender:Any?) {openFile(sender)}
}
extension Comparable {func clamped(to range:ClosedRange<Self>)->Self {min(max(self,range.lowerBound),range.upperBound)}}
extension URL {var abbreviatingWithTildeInPath:String {(path as NSString).abbreviatingWithTildeInPath}}
