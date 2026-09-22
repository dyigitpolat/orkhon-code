import AppKit

private final class RemoteNode:NSObject {
    let entry:RemoteEntry
    var children:[RemoteNode]=[]
    var loaded=false,loading=false
    init(_ entry:RemoteEntry) {self.entry=entry}
}

@MainActor
final class RemoteTreePanel:NSView,NSOutlineViewDataSource,NSOutlineViewDelegate {
    let connection:RemoteWorkspace
    private let outline=NSOutlineView(),scroll=NSScrollView(),heading=NSTextField(labelWithString:""),message=NSTextField(wrappingLabelWithString:"")
    private let refresh=NSButton(),disconnect=NSButton()
    private var root:RemoteNode?
    private var generation=0
    var onOpen:((String)->Void)?,onDisconnect:(()->Void)?
    init(frame:NSRect,connection:RemoteWorkspace) {
        self.connection=connection;super.init(frame:frame)
        let col=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("name"));outline.addTableColumn(col);outline.outlineTableColumn=col;outline.headerView=nil;outline.rowHeight=27;outline.style = .sourceList;outline.dataSource=self;outline.delegate=self;outline.target=self;outline.doubleAction=#selector(openRow);outline.setAccessibilityLabel("Remote SSH files")
        scroll.documentView=outline;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false
        heading.stringValue=connection.host;heading.font = .systemFont(ofSize:11,weight:.semibold);heading.lineBreakMode = .byTruncatingMiddle
        refresh.image=NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"Refresh remote files");refresh.isBordered=false;refresh.target=self;refresh.action=#selector(reload)
        disconnect.image=NSImage(systemSymbolName:"xmark",accessibilityDescription:"Disconnect SSH");disconnect.isBordered=false;disconnect.target=self;disconnect.action=#selector(closeConnection)
        message.font = .systemFont(ofSize:11);message.textColor = .secondaryLabelColor
        for view in [scroll,heading,refresh,disconnect,message] {addSubview(view)}
    }
    required init?(coder:NSCoder) {fatalError("Use init(frame:connection:)")}
    override func layout() {super.layout();heading.frame=NSRect(x:12,y:bounds.height-31,width:max(60,bounds.width-76),height:20);refresh.frame=NSRect(x:bounds.width-61,y:bounds.height-34,width:24,height:25);disconnect.frame=NSRect(x:bounds.width-31,y:bounds.height-34,width:24,height:25);message.frame=NSRect(x:12,y:8,width:bounds.width-24,height:44);scroll.frame=NSRect(x:0,y:56,width:bounds.width,height:max(0,bounds.height-96))}
    func applyTheme(_ theme:Theme) {wantsLayer=true;layer?.backgroundColor=theme.panelColor.cgColor;outline.backgroundColor=theme.panelColor;heading.textColor=theme.accentColor;outline.reloadData()}
    func showMessage(_ value:String) {message.stringValue=value;message.toolTip=value}
    func setRoot(_ path:String) {generation+=1;root=RemoteNode(RemoteEntry(path:path,directory:true,symbolicLink:false));outline.reloadData();if let root {load(root)}}
    @objc func reload() {setRoot(connection.directory)}
    @objc private func closeConnection() {onDisconnect?()}
    private func load(_ node:RemoteNode) {
        guard !node.loading else{return};node.loading=true;let revision=generation;let path=node.entry.path;let connection=connection
        showMessage("Loading \((path as NSString).lastPathComponent)…")
        Task { [weak self,weak node] in
            let result=await Task.detached {Result{try connection.list(path)}}.value
            guard let self,let node,self.generation==revision else{return};node.loading=false
            switch result {
            case .success(let entries):node.children=entries.map(RemoteNode.init);node.loaded=true;self.outline.reloadItem(node===self.root ? nil:node,reloadChildren:true);self.showMessage(connection.directory)
            case .failure(let error):self.showMessage(error.localizedDescription)
            }
        }
    }
    func outlineView(_ outlineView:NSOutlineView,numberOfChildrenOfItem item:Any?)->Int {(item as? RemoteNode ?? root)?.children.count ?? 0}
    func outlineView(_ outlineView:NSOutlineView,child index:Int,ofItem item:Any?)->Any {(item as? RemoteNode ?? root)!.children[index]}
    func outlineView(_ outlineView:NSOutlineView,isItemExpandable item:Any)->Bool {(item as? RemoteNode)?.entry.directory == true}
    func outlineView(_ outlineView:NSOutlineView,shouldExpandItem item:Any)->Bool {if let node=item as? RemoteNode,!node.loaded {load(node)};return true}
    func outlineView(_ outlineView:NSOutlineView,viewFor tableColumn:NSTableColumn?,item:Any)->NSView? {
        guard let node=item as? RemoteNode else{return nil}
        let cell=NSTableCellView();let icon=NSImageView(image:NSImage(systemSymbolName:node.entry.directory ? "folder":(node.entry.symbolicLink ? "link":"doc.text"),accessibilityDescription:nil) ?? NSImage());icon.frame=NSRect(x:0,y:5,width:16,height:16)
        let label=NSTextField(labelWithString:node.entry.name);label.font = .systemFont(ofSize:12);label.lineBreakMode = .byTruncatingMiddle;label.frame=NSRect(x:22,y:4,width:max(70,bounds.width-60),height:20);label.autoresizingMask=[.width]
        cell.addSubview(icon);cell.addSubview(label);cell.textField=label;cell.imageView=icon;cell.toolTip=node.entry.path;return cell
    }
    @objc private func openRow() {guard let node=outline.item(atRow:outline.clickedRow) as? RemoteNode else{return};if node.entry.directory {outline.isItemExpanded(node) ? outline.collapseItem(node):outline.expandItem(node)} else {onOpen?(node.entry.path)}}
}
