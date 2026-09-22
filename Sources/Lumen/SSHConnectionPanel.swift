import AppKit

/// Lists literal aliases only. OpenSSH itself evaluates Host/Match/Include on connect.
enum SSHProfiles {
    static func aliases(config:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config"))->[String] {
        var visited=Set<String>(),aliases=Set<String>()
        func read(_ file:URL,depth:Int) {
            guard depth<8,visited.insert(file.standardizedFileURL.path).inserted,let text=try? String(contentsOf:file,encoding:.utf8),text.utf8.count<1024*1024 else{return}
            for line in text.components(separatedBy:.newlines) {
                let words=line.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false).first?.split(whereSeparator:{$0.isWhitespace || $0=="="}).map(String.init) ?? []
                guard let keyword=words.first?.lowercased() else{continue}
                if keyword=="host" {for host in words.dropFirst() where !host.contains("*") && !host.contains("?") && !host.hasPrefix("!") && RemoteWorkspace.validHost(host) {aliases.insert(host)}}
                if keyword=="include" {
                    for pattern in words.dropFirst() {
                        let path=(pattern.trimmingCharacters(in:CharacterSet(charactersIn:"\"'")) as NSString).expandingTildeInPath
                        let url=path.hasPrefix("/") ? URL(fileURLWithPath:path):config.deletingLastPathComponent().appendingPathComponent(path)
                        if url.lastPathComponent.contains("*") || url.lastPathComponent.contains("?") {
                            let names=(try? FileManager.default.contentsOfDirectory(at:url.deletingLastPathComponent(),includingPropertiesForKeys:nil)) ?? []
                            for match in names where fnmatch(url.lastPathComponent,match.lastPathComponent,0)==0 {read(match,depth:depth+1)}
                        } else {read(url,depth:depth+1)}
                    }
                }
            }
        }
        read(config,depth:0);return aliases.sorted{$0.localizedStandardCompare($1) == .orderedAscending}
    }
}

@MainActor
final class SSHConnectionPanel:NSWindowController,NSTableViewDataSource,NSTableViewDelegate {
    private let theme:Theme
    private let host=CenteredTextField(),user=CenteredTextField(),port=CenteredTextField(),path=CenteredTextField()
    private let message=NSTextField(wrappingLabelWithString:"")
    private let action=PillButton(title:"Connect",target:nil,action:nil),cancel=PillButton(title:"Cancel",target:nil,action:nil)
    private let table=NSTableView(),scroll=NSScrollView()
    private var connection:RemoteWorkspace?
    private var directory=""
    private var entries:[RemoteEntry]=[]
    private var palette:CommandPalette?
    private var generation=0
    private var busy=false,finished=false
    private let onConnected:(RemoteWorkspace)->Void
    init(parent:NSWindow,theme:Theme,onConnected:@escaping (RemoteWorkspace)->Void) {
        self.theme=theme;self.onConnected=onConnected
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:570,height:422),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:panel);panel.title="Connect over SSH";panel.titleVisibility = .hidden;panel.titlebarAppearsTransparent=true;panel.isReleasedWhenClosed=false;panel.appearance=parent.effectiveAppearance
        action.target=self;action.action=#selector(proceed);action.keyEquivalent="\r"
        cancel.target=self;cancel.action=#selector(cancelConnection);cancel.keyEquivalent="\u{1b}"
        host.stringValue=UserDefaults.standard.string(forKey:"lastSSHHost") ?? ""
        buildConnectionForm()
    }
    required init?(coder:NSCoder) {fatalError("Use init(parent:theme:onConnected:)")}
    func present(on parent:NSWindow) {guard let window else{return};parent.beginSheet(window);window.makeFirstResponder(host)}
    private func base(title:String,detail:String)->Surface {
        let content=Surface();content.color(theme.background);window?.contentView=content
        let heading=NSTextField(labelWithString:title);heading.font = .systemFont(ofSize:23,weight:.semibold);heading.textColor=theme.foreground;heading.frame=NSRect(x:28,y:357,width:514,height:34);content.addSubview(heading)
        let subtitle=NSTextField(wrappingLabelWithString:detail);subtitle.font = .systemFont(ofSize:12);subtitle.textColor=NSColor(hex:theme.muted);subtitle.frame=NSRect(x:30,y:310,width:510,height:42);content.addSubview(subtitle)
        message.font = .systemFont(ofSize:11);message.textColor=NSColor(hex:theme.muted);message.frame=NSRect(x:30,y:68,width:510,height:42);content.addSubview(message)
        for b in [action,cancel] {b.accent=theme.accentColor;b.foreground=theme.foreground;b.font = .systemFont(ofSize:12,weight:.medium);content.addSubview(b)}
        cancel.frame=NSRect(x:28,y:22,width:88,height:34);action.frame=NSRect(x:350,y:22,width:190,height:34);action.state = .on
        return content
    }
    private func field(_ input:CenteredTextField,placeholder:String,frame:NSRect,on content:NSView) {
        let surface=Surface(frame:frame);surface.color(theme.panelColor);surface.layer?.cornerRadius=7;surface.layer?.borderWidth=1;surface.layer?.borderColor=theme.accentColor.withAlphaComponent(0.25).cgColor
        input.isBezeled=false;input.isBordered=false;input.drawsBackground=false;input.focusRingType = .none;input.font = .systemFont(ofSize:13);input.textColor=theme.foreground;input.placeholderString=placeholder;input.setAccessibilityLabel(placeholder);input.frame=surface.bounds.insetBy(dx:12,dy:0)
        surface.addSubview(input);content.addSubview(surface)
    }
    private func label(_ title:String,x:CGFloat,y:CGFloat,on content:NSView) {
        let label=NSTextField(labelWithString:title);label.font = .systemFont(ofSize:11,weight:.medium);label.textColor=NSColor(hex:theme.muted);label.frame=NSRect(x:x,y:y,width:300,height:18);content.addSubview(label)
    }
    private func buildConnectionForm() {
        let content=base(title:"Connect over SSH",detail:"Connect with an SSH profile or a hostname. Choose your workspace folder after signing in.")
        label("HOST",x:30,y:278,on:content);field(host,placeholder:"Profile name or user@hostname",frame:NSRect(x:28,y:236,width:402,height:38),on:content)
        let profiles=PillButton(title:"Profiles…",target:self,action:#selector(selectProfile));profiles.accent=theme.accentColor;profiles.foreground=theme.foreground;profiles.frame=NSRect(x:440,y:236,width:100,height:38);content.addSubview(profiles)
        label("USER · OPTIONAL",x:30,y:196,on:content);label("PORT · OPTIONAL",x:363,y:196,on:content)
        field(user,placeholder:"Use SSH configuration",frame:NSRect(x:28,y:154,width:321,height:38),on:content)
        field(port,placeholder:"22",frame:NSRect(x:361,y:154,width:179,height:38),on:content)
        message.stringValue="Your SSH keys and agent are used automatically. A secure password prompt appears when the server needs one."
    }
    @objc private func selectProfile() {
        guard !busy,let window else{return}
        let items=SSHProfiles.aliases().map{PaletteItem(title:$0,subtitle:"SSH profile",shortcut:"",identifier:$0)}
        palette=CommandPalette(parent:window,title:"SSH profiles",placeholder:"Search profiles…",items:items,compact:true) { [weak self] item in self?.host.stringValue=item.identifier;self?.user.stringValue="";self?.port.stringValue="" }
        palette?.present()
    }
    @objc private func proceed() {
        guard !busy else{return}
        if let connection {connection.directory=entries.indices.contains(table.selectedRow) ? entries[table.selectedRow].path:directory;finished=true;dismiss();onConnected(connection);return}
        let raw=host.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),username=user.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let destination=username.isEmpty ? raw:username+"@"+raw
        guard username.isEmpty || (!raw.contains("@") && username.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil) else {message.stringValue="Use a hostname without user@ when entering a separate user.";return}
        let portText=port.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard portText.isEmpty || (Int(portText).map{(1...65535).contains($0)} ?? false) else {message.stringValue="Enter a port between 1 and 65535.";return}
        do {
            let remote=try RemoteWorkspace(host:destination,directory:"",port:Int(portText));connection=remote
            busy=true;action.isEnabled=false;host.isEnabled=false;user.isEnabled=false;port.isEnabled=false;message.stringValue="Connecting to \(destination)… Complete any authentication prompt to continue."
            let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Orkhon SSH Authentication.app/Contents/MacOS/OrkhonSSHAskpass")
            Task { [weak self] in
                let result=await Task.detached{Result{try remote.connect(askpass:helper);return try remote.canonicalDirectory("")}}.value
                guard let self,!self.finished,self.connection === remote else{return}
                self.busy=false
                switch result {
                case .success(let home):UserDefaults.standard.set(destination,forKey:"lastSSHHost");self.buildFolderForm();self.loadDirectory(home)
                case .failure(let error):remote.disconnect();self.connection=nil;self.action.isEnabled=true;self.host.isEnabled=true;self.user.isEnabled=true;self.port.isEnabled=true;self.message.stringValue=error.localizedDescription
                }
            }
        } catch {message.stringValue=error.localizedDescription}
    }
    private func buildFolderForm() {
        let content=base(title:"Choose a remote folder",detail:"Connected to \(connection?.host ?? "server"). Browse to a folder or enter its full path.")
        action.title="Open workspace"
        field(path,placeholder:"Remote directory",frame:NSRect(x:28,y:265,width:464,height:36),on:content);path.target=self;path.action=#selector(goToPath)
        let up=iconButton("arrow.up","Parent directory",target:self,action:#selector(goUp));up.frame=NSRect(x:504,y:266,width:36,height:34);content.addSubview(up)
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("folder"));column.width=480;table.addTableColumn(column);table.headerView=nil;table.rowHeight=30;table.intercellSpacing=NSSize(width:0,height:2);table.backgroundColor=theme.panelColor;table.dataSource=self;table.delegate=self;table.target=self;table.doubleAction=#selector(openDirectory)
        table.setAccessibilityLabel("Remote folders")
        scroll.frame=NSRect(x:28,y:115,width:512,height:140);scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.wantsLayer=true;scroll.layer?.cornerRadius=8;content.addSubview(scroll)
    }
    @objc private func goToPath() {loadDirectory(path.stringValue)}
    @objc private func goUp() {loadDirectory((directory as NSString).deletingLastPathComponent)}
    @objc private func openDirectory() {let row=table.clickedRow>=0 ? table.clickedRow:table.selectedRow;if entries.indices.contains(row){loadDirectory(entries[row].path)}}
    private func loadDirectory(_ requested:String) {
        guard let connection else{return};generation+=1;let revision=generation
        busy=true;action.isEnabled=false;message.stringValue="Loading folders…"
        Task { [weak self] in
            let result=await Task.detached {Result{let canonical=try connection.canonicalDirectory(requested);return (canonical,try connection.list(canonical).filter{$0.directory && !$0.symbolicLink})}}.value
            guard let self,!self.finished,self.generation==revision else{return};self.busy=false
            switch result {
            case .success(let (canonical,entries)):self.directory=canonical;self.path.stringValue=canonical;self.entries=entries;self.table.reloadData();self.table.deselectAll(nil);self.action.isEnabled=true;self.message.stringValue="\(entries.count) folders · Select a folder to open it, or double-click to browse. No selection opens this folder."
            case .failure(let error):self.message.stringValue=error.localizedDescription;self.action.isEnabled = !self.directory.isEmpty
            }
        }
    }
    func numberOfRows(in tableView:NSTableView)->Int {entries.count}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let cell=NSTableCellView(),icon=NSImageView(image:NSImage(systemSymbolName:"folder",accessibilityDescription:nil)!),label=NSTextField(labelWithString:entries[row].name)
        icon.contentTintColor=theme.accentColor;icon.frame=NSRect(x:10,y:7,width:16,height:16);label.frame=NSRect(x:36,y:6,width:440,height:18);label.font = .systemFont(ofSize:12);label.textColor=theme.foreground;label.lineBreakMode = .byTruncatingMiddle;cell.addSubview(icon);cell.addSubview(label);return cell
    }
    func cancelPendingConnection() {cancelConnection()}
    @objc private func cancelConnection() {finished=true;generation+=1;connection?.disconnect();dismiss()}
    private func dismiss() {palette?.close();if let window {window.sheetParent?.endSheet(window);window.orderOut(nil)}}
}
