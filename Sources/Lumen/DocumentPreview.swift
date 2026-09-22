import AppKit
import WebKit

enum PreviewMode:Int,Codable {case source,preview,split}
enum PreviewKind {case markdown,html}

/// Debounces typing without postponing a visible update indefinitely.
@MainActor
final class PreviewRefresh {
    private var firstChange:TimeInterval?
    private var work:DispatchWorkItem?
    let idle:TimeInterval,maxDelay:TimeInterval
    init(idle:TimeInterval=0.25,maxDelay:TimeInterval=1) {self.idle=idle;self.maxDelay=maxDelay}
    func schedule(_ action:@escaping ()->Void) {
        let now=ProcessInfo.processInfo.systemUptime
        if firstChange == nil {firstChange=now}
        work?.cancel()
        let delay=max(0,min(idle,maxDelay-(now-firstChange!)))
        let item=DispatchWorkItem { [weak self] in self?.firstChange=nil;self?.work=nil;action() }
        work=item;DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:item)
    }
    func cancel() {work?.cancel();work=nil;firstChange=nil}
    deinit {work?.cancel()}
}

@MainActor
final class PreviewDeck:NSView {
    let source=NSView(),preview=NSView(),split=PaneSplitView(frame:.zero)
    let toolbar=Surface()
    private let kindLabel=NSTextField(labelWithString:"")
    private var buttons:[PillButton]=[]
    var onMode:((PreviewMode)->Void)?
    var mode=PreviewMode.source
    var available=false
    private var allowSplit=true
    override init(frame:NSRect) {
        super.init(frame:frame)
        split.addArrangedSubview(source);split.addArrangedSubview(preview);addSubview(split);addSubview(toolbar)
        kindLabel.font = .systemFont(ofSize:11,weight:.medium);toolbar.addSubview(kindLabel)
        for (i,title) in ["Source","Preview","Side by side"].enumerated() {
            let button=PillButton(title:title,target:self,action:#selector(choose(_:)));button.tag=i
            button.font = .systemFont(ofSize:11,weight:.medium);button.setAccessibilityLabel(title);buttons.append(button);toolbar.addSubview(button)
        }
    }
    required init?(coder:NSCoder) {fatalError("Use init(frame:)")}
    @objc private func choose(_ sender:NSButton) {if let mode=PreviewMode(rawValue:sender.tag){onMode?(mode)}}
    func configure(kind:PreviewKind?,mode:PreviewMode,theme:Theme,allowSplit:Bool=true) {
        available=kind != nil;self.allowSplit=allowSplit;self.mode=available ? mode:.source
        toolbar.color(theme.panelColor);kindLabel.stringValue=kind == .html ? "HTML":"MARKDOWN";kindLabel.textColor=NSColor(hex:theme.muted)
        toolbar.isHidden = !available;source.isHidden=self.mode == .preview;preview.isHidden=self.mode == .source
        for button in buttons {button.isHidden=button.tag==2 && !allowSplit;button.isEnabled=button.tag != 2 || allowSplit;button.toolTip=button.tag == 2 && !allowSplit ? "Close the second editor pane to use side-by-side preview":nil;button.state=button.tag==self.mode.rawValue ? .on:.off;button.accent=theme.accentColor;button.foreground=theme.foreground;button.needsDisplay=true}
        needsLayout=true
    }
    override func layout() {
        super.layout();let h:CGFloat=available ? 38:0
        toolbar.frame=NSRect(x:0,y:bounds.height-h,width:bounds.width,height:h)
        kindLabel.frame=NSRect(x:16,y:11,width:90,height:16)
        kindLabel.isHidden=bounds.width<400
        var x=max(8,bounds.width-(allowSplit ? 281:168))
        for (i,button) in buttons.enumerated() {let w:CGFloat=i==2 ? 102:76;button.frame=NSRect(x:x,y:5,width:w,height:28);x+=w+5}
        split.frame=NSRect(x:0,y:0,width:bounds.width,height:max(0,bounds.height-h))
        split.adjustSubviews()
        for host in [source,preview] {for child in host.subviews {child.frame=host.bounds}}
    }

}

/// Created only when an HTML preview is requested; no WebKit view/process at launch.
@MainActor
final class HTMLPreview:NSView,WKNavigationDelegate {
    let web:WKWebView
    private let errorLabel=NSTextField(wrappingLabelWithString:"")
    private let cache=FileManager.default.temporaryDirectory.appendingPathComponent("orkhon-preview-"+UUID().uuidString,isDirectory:true)
    private var revision=0
    private var scrollPosition:CGPoint?
    private var sourceURL:URL?
    override init(frame:NSRect) {
        let configuration=WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically=false
        web=WKWebView(frame:.zero,configuration:configuration)
        super.init(frame:frame);web.navigationDelegate=self;addSubview(web)
        errorLabel.isHidden=true;errorLabel.textColor = .secondaryLabelColor;addSubview(errorLabel)
        web.setAccessibilityLabel("HTML preview")
        try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    }
    required init?(coder:NSCoder) {fatalError("Use init(frame:)")}
    deinit {try? FileManager.default.removeItem(at:cache)}
    override func layout() {
        super.layout();web.frame=bounds
        // CGRect.insetBy returns a null/infinite rectangle for a collapsed host.
        errorLabel.frame=NSRect(x:min(24,bounds.width/2),y:min(24,bounds.height/2),width:max(0,bounds.width-48),height:max(0,bounds.height-48))
    }
    func render(_ text:String,url:URL?,modified:Bool) {
        revision+=1;let generation=revision
        guard text.utf8.count<=10*1024*1024 else {errorLabel.stringValue="This HTML file is too large for live preview. Its source remains fully editable.";errorLabel.isHidden=false;return}
        errorLabel.isHidden=true
        let same=sourceURL==url;sourceURL=url
        web.evaluateJavaScript("[window.scrollX,window.scrollY]") { [weak self] value,_ in
            guard let self,self.revision==generation else{return}
            self.scrollPosition=same ? (value as? [Double]).flatMap{$0.count==2 ? CGPoint(x:$0[0],y:$0[1]):nil}:nil
            if let url,!modified {self.web.loadFileURL(url,allowingReadAccessTo:URL(fileURLWithPath:"/"));return}
            // A file URL preserves browser file-origin semantics. <base> resolves relative
            // assets against the real document directory, including parent directories.
            var html=text
            if let base=url?.deletingLastPathComponent().absoluteString {
                let tag="<base href=\""+base.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"\"",with:"&quot;")+"\">"
                if html.range(of:"<base\\b",options:[.regularExpression,.caseInsensitive]) == nil {
                    if let head=html.range(of:"<head\\b[^>]*>",options:[.regularExpression,.caseInsensitive]) {html.insert(contentsOf:tag,at:head.upperBound)}
                    else {html=tag+html}
                }
            }
            let file=self.cache.appendingPathComponent("preview.html")
            do {try html.write(to:file,atomically:true,encoding:.utf8);self.web.loadFileURL(file,allowingReadAccessTo:URL(fileURLWithPath:"/"))}
            catch {self.errorLabel.stringValue=error.localizedDescription;self.errorLabel.isHidden=false}
        }
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        if let point=scrollPosition {webView.evaluateJavaScript("window.scrollTo(\(point.x),\(point.y))",completionHandler:nil);scrollPosition=nil}
    }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {
        if (error as NSError).code != NSURLErrorCancelled {errorLabel.stringValue=error.localizedDescription;errorLabel.isHidden=false}
    }
}

extension DocumentTab {
    var previewKind:PreviewKind? {
        if isWelcome || language?.lexer=="markdown" {return .markdown}
        let ext=(url?.pathExtension ?? remotePath.map{($0 as NSString).pathExtension} ?? "").lowercased()
        return ["html","htm","xhtml","shtml"].contains(ext) ? .html:nil
    }
}

extension EditorWindowController {
    func setPreviewMode(_ mode:PreviewMode) {
        guard let d=current,d.previewKind != nil,mode != .split || !editorIsSplit else{return}
        d.previewMode=mode;updateMarkdownPreview();if mode != .preview {d.editor.focus()}
    }
    @objc func toggleMarkdown(_ sender:Any?) {setPreviewMode(current?.previewMode == .source ? .preview:.source)}
    @objc func splitPreview(_ sender:Any?) {setPreviewMode(.split)}
    func updateMarkdownPreview() {activePane.updatePreview();layoutEditor()}
    func schedulePreview() {if firstPane.document === current {firstPane.schedulePreview()};if editorIsSplit && secondPane.document === current {secondPane.schedulePreview()}}
    func renderPreview() {activePane.render()}
}
