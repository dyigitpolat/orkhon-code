import AppKit

let documentTabPasteboard=NSPasteboard.PasteboardType("app.orkhon.editor.document-tab")

private final class PaneDropOverlay:NSView {
    var left=false
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func draw(_ dirtyRect:NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        NSRect(x:left ? 0:bounds.midX,y:0,width:bounds.width/2,height:bounds.height).fill()
    }
}

@MainActor
final class EditorPane:NSView {
    let deck=PreviewDeck(frame:.zero),refresh=PreviewRefresh()
    let titleBar=Surface(),title=NSTextField(labelWithString:"")
    let closeSplit=NSButton()
    var document:DocumentTab?
    var markdown:MarkdownView?,html:HTMLPreview?
    private var lastAssetKey:String?
    var externalControls:InlineExternalControls?
    weak var owner:EditorWindowController?
    var split=false
    private let dropOverlay=PaneDropOverlay()
    private var dropSide:Bool? {didSet{dropOverlay.isHidden=dropSide==nil;dropOverlay.left=dropSide ?? false;dropOverlay.needsDisplay=true}}
    override init(frame:NSRect) {
        super.init(frame:frame);addSubview(deck);addSubview(titleBar);titleBar.addSubview(title);titleBar.addSubview(closeSplit)
        title.font = .systemFont(ofSize:11,weight:.medium);title.lineBreakMode = .byTruncatingMiddle
        closeSplit.isBordered=false;closeSplit.image=NSImage(systemSymbolName:"xmark",accessibilityDescription:"Close split pane");closeSplit.target=self;closeSplit.action=#selector(collapse)
        closeSplit.toolTip="Close split pane (keep tab open)"
        deck.onMode = { [weak self] mode in guard let self,let d=self.document else{return};self.owner?.focusDocument(d);self.owner?.setPreviewMode(mode) }
        dropOverlay.isHidden=true;addSubview(dropOverlay,positioned:.above,relativeTo:nil)
        registerForDraggedTypes([documentTabPasteboard])
    }
    required init?(coder:NSCoder) {fatalError("Use init(frame:)")}
    @objc private func collapse() {
        guard let owner else{return}
        owner.collapseEditorSplit(keeping:owner.firstPane === self ? owner.secondPane.document:owner.firstPane.document)
    }
    func bind(_ document:DocumentTab,owner:EditorWindowController) {
        self.owner=owner
        if self.document !== document {self.document?.editor.removeFromSuperview();self.document=document;deck.split.ratio=0.5;deck.source.addSubview(document.editor)}
        updatePreview()
    }
    override func layout() {
        super.layout();dropOverlay.frame=bounds;let h:CGFloat=split ? 26:0
        titleBar.isHidden = !split;titleBar.frame=NSRect(x:0,y:bounds.height-h,width:bounds.width,height:h)
        title.frame=NSRect(x:12,y:5,width:max(60,bounds.width-46),height:16);closeSplit.frame=NSRect(x:bounds.width-28,y:3,width:22,height:20)
        deck.frame=NSRect(x:0,y:0,width:bounds.width,height:max(0,bounds.height-h));deck.needsLayout=true
    }
    func updatePreview() {
        guard let d=document,let owner else{return}
        refresh.cancel();markdown?.removeFromSuperview();html?.removeFromSuperview();externalControls?.removeFromSuperview();d.editor.isHidden=false
        if split && d.previewMode == .split {d.previewMode = .source}
        if document?.previewKind == nil {d.previewMode = .source}
        title.stringValue=d.title;title.textColor=owner.current === d ? owner.theme.accentColor:owner.theme.foreground
        titleBar.color(owner.theme.panelColor);closeSplit.contentTintColor=owner.theme.foreground
        deck.configure(kind:d.previewKind,mode:d.previewMode,theme:owner.theme,allowSplit:!split)
        if d.externalChange != nil {
            if externalControls?.document !== d {externalControls=InlineExternalControls(document:d,owner:owner)}
            if let externalControls {deck.source.addSubview(externalControls);externalControls.reload()}
        } else {externalControls=nil}
        if d.previewMode != .source {
            if d.previewKind == .markdown {
                if markdown == nil || markdown?.nativeOnly != d.isWelcome {markdown=MarkdownView(nativeOnly:d.isWelcome);markdown?.onOpen = { [weak owner] in owner?.openURL($0) }}
                if let markdown {markdown.onOpenRemote = { [weak owner] in owner?.openRemoteFile($0) };markdown.applyTheme(owner.theme);deck.preview.addSubview(markdown)}
            } else if d.previewKind == .html {
                if html == nil {html=HTMLPreview(frame:.zero)}
                if let html {deck.preview.addSubview(html)}
            }
            render()
        }
        needsLayout=true
    }
    func schedulePreview() {guard document?.previewMode != .source else{return};refresh.schedule{[weak self] in self?.render()}}
    func refreshFilesystemPreview() {
        guard let d=document,lastAssetKey != d.id+":"+String(d.previewAssetRevision) else{return}
        render(invalidateAssets:true)
    }
    func render(invalidateAssets:Bool=false) {
        guard let d=document,d.previewMode != .source else{return}
        let key=d.id+":"+String(d.previewAssetRevision)
        let reload=invalidateAssets || (lastAssetKey != nil && lastAssetKey != key);lastAssetKey=key
        if d.previewKind == .markdown {markdown?.render(d.editor.text,url:d.url,documentID:d.id,assetRevision:d.previewAssetRevision,remote:d.remotePath==nil ? nil:owner?.remote,remotePath:d.remotePath)}
        else if d.previewKind == .html {html?.render(d.editor.text,url:d.url,modified:d.isModified,remote:d.remotePath==nil ? nil:owner?.remote,remotePath:d.remotePath,invalidateAssets:reload)}
    }
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {draggingUpdated(sender)}
    override func draggingUpdated(_ sender:NSDraggingInfo)->NSDragOperation {
        guard let id=sender.draggingPasteboard.string(forType:documentTabPasteboard),let owner,owner.coordinator?.windows.contains(where:{$0.documents.contains{$0.id==id && !$0.loading}})==true else{return []}
        dropSide=convert(sender.draggingLocation,from:nil).x<bounds.midX;needsDisplay=true;return .move
    }
    override func draggingExited(_ sender:NSDraggingInfo?) {dropSide=nil;needsDisplay=true}
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        defer{dropSide=nil;needsDisplay=true}
        guard let id=sender.draggingPasteboard.string(forType:documentTabPasteboard),let owner,let coordinator=owner.coordinator,let source=coordinator.windows.first(where:{$0.documents.contains{$0.id==id}}),let document=source.documents.first(where:{$0.id==id}) else{return false}
        if source !== owner {
            // A remote connection is a window workspace; mixing unrelated hosts is unsafe.
            if document.remotePath != nil && owner.remote !== source.remote {return false}
            source.detachForTransfer(document);owner.documents.append(document);owner.configureEditor(document)
        }
        owner.splitEditor(with:document,onLeft:dropSide ?? false,replacing:self);return true
    }
}

extension EditorWindowController {
    func layoutEditorPanes() {firstPane.isHidden=false;editorSplit.adjustSubviews()}
    var editorIsSplit:Bool {!secondPane.isHidden}
    var activePane:EditorPane {secondPane.document === current && editorIsSplit ? secondPane:firstPane}
    func focusDocument(_ document:DocumentTab) {
        guard let index=documents.firstIndex(where:{$0 === document}),selected != index else{return}
        selected=index;rebuildTabs();revealSelectedTab();updateStatus();updateTreeOpenFiles()
        for pane in [firstPane,secondPane] {pane.title.textColor=pane.document === current ? theme.accentColor:theme.foreground}
    }
    func splitEditor(with document:DocumentTab,onLeft:Bool,replacing pane:EditorPane?=nil) {
        guard !document.loading,let active=current else{return}
        if !editorIsSplit {
            guard let companion=active !== document ? active:documents.reversed().first(where:{$0 !== document && !$0.loading}) else{return}
            firstPane.split=true;secondPane.split=true;secondPane.isHidden=false
            if companion.previewMode == .split {companion.previewMode = .source}
            if document.previewMode == .split {document.previewMode = .source}
            let left=onLeft ? document:companion,right=onLeft ? companion:document
            firstPane.document?.editor.removeFromSuperview();firstPane.document=nil
            firstPane.bind(left,owner:self);secondPane.bind(right,owner:self)
            editorSplit.ratio=0.5;layoutEditorPanes()
        } else {
            if document === firstPane.document || document === secondPane.document {focusDocument(document);document.editor.focus();return}
            let target=pane ?? (onLeft ? firstPane:secondPane);target.bind(document,owner:self)
        }
        focusDocument(document);layoutEditor();document.editor.focus();persistSession()
    }
    func collapseEditorSplit(keeping document:DocumentTab?) {
        guard editorIsSplit else{return}
        let keep=document ?? current ?? firstPane.document
        firstPane.document?.editor.removeFromSuperview();secondPane.document?.editor.removeFromSuperview()
        firstPane.document=nil;secondPane.document=nil;secondPane.isHidden=true;firstPane.split=false;secondPane.refresh.cancel()
        if let keep {firstPane.bind(keep,owner:self);focusDocument(keep);keep.editor.focus()}
        layoutEditorPanes();layoutEditor()
    }
    @objc func splitTabLeft(_ sender:NSMenuItem) {if let d=sender.representedObject as? DocumentTab {splitEditor(with:d,onLeft:true)}}
    @objc func splitTabRight(_ sender:NSMenuItem) {if let d=sender.representedObject as? DocumentTab {splitEditor(with:d,onLeft:false)}}
    func detachForTransfer(_ document:DocumentTab) {
        if editorIsSplit {collapseEditorSplit(keeping:firstPane.document === document ? secondPane.document:firstPane.document)}
        document.recoveryWork?.cancel();document.editor.removeFromSuperview()
        documents.removeAll{$0 === document};selected = -1
        if documents.isEmpty {newDocument(nil)} else {selectDocument(0)}
        updateAutomaticWorkspace()
    }
}
