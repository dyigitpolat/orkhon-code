import AppKit
@preconcurrency import WebKit
import UniformTypeIdentifiers

/// Runtime resources are local and immutable. Document images have a separate
/// origin and cannot be executed as scripts or styles by the preview's CSP.
final class MarkdownResources:NSObject,WKURLSchemeHandler {
    private let root:URL
    private var active=Set<ObjectIdentifier>()
    private let queue=DispatchQueue(label:"app.orkhon.markdown.resources",qos:.userInitiated,attributes:.concurrent)
    init(root:URL) {self.root=root.resolvingSymlinksInPath();super.init()}
    func webView(_ webView:WKWebView,start urlSchemeTask:WKURLSchemeTask) {
        let id=ObjectIdentifier(urlSchemeTask);active.insert(id)
        let requestURL=urlSchemeTask.request.url
        queue.async { [self] in
            let result:Result<(Data,String),Error> = Result {
                guard let url=requestURL else {throw URLError(.badURL)}
                let file:URL
                if url.scheme == "orkhon-preview",url.host == "bundle" {
                    file=root.appendingPathComponent(url.path).resolvingSymlinksInPath()
                    guard file.path.hasPrefix(root.path+"/") else {throw URLError(.noPermissionsToReadFile)}
                } else if url.scheme == "orkhon-document",url.host == "local" {
                    file=URL(fileURLWithPath:url.path).resolvingSymlinksInPath()
                    guard ["png","jpg","jpeg","gif","webp","svg","avif","heic","tiff","bmp","ico"].contains(file.pathExtension.lowercased()) else {throw URLError(.noPermissionsToReadFile)}
                } else {throw URLError(.unsupportedURL)}
                let size=try file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
                guard size.isRegularFile == true,(size.fileSize ?? Int.max)<=16*1024*1024 else {throw URLError(.dataLengthExceedsMaximum)}
                let mime:[String:String]=["js":"application/javascript","css":"text/css","html":"text/html","woff2":"font/woff2","svg":"image/svg+xml"]
                return (try Data(contentsOf:file),mime[file.pathExtension] ?? UTType(filenameExtension:file.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
            }
            // WebKit synchronously marshals scheme callbacks to the main run loop.
            // Never hold a worker lock while calling it: a new main-thread request
            // can otherwise wait on that lock while the worker waits on WebKit.
            DispatchQueue.main.async { [self] in
                guard active.remove(id) != nil else{return}
                switch result {
                case .success(let (data,mime)):
                    urlSchemeTask.didReceive(URLResponse(url:requestURL!,mimeType:mime,expectedContentLength:data.count,textEncodingName:mime.hasPrefix("text/") || mime.contains("javascript") ? "utf-8":nil))
                    urlSchemeTask.didReceive(data);urlSchemeTask.didFinish()
                case .failure(let error):urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }
    func webView(_ webView:WKWebView,stop urlSchemeTask:WKURLSchemeTask) {active.remove(ObjectIdentifier(urlSchemeTask))}
}

/// One renderer per visible pane, created only on explicit Markdown preview.
/// The built-in welcome page keeps its small native TextKit renderer.
@MainActor
final class MarkdownView:NSView,WKNavigationDelegate {
    let nativeOnly:Bool
    private(set) var web:WKWebView?
    private var native:NativeMarkdownView?
    private let errorLabel=NSTextField(wrappingLabelWithString:"")
    private var ready=false,rendering=false
    private var pending:(String,URL?,String)?
    private var theme=Theme.all[0]
    var onOpen:((URL)->Void)? {didSet{native?.onOpen=onOpen}}
    init(nativeOnly:Bool=false) {
        self.nativeOnly=nativeOnly;super.init(frame:.zero)
        wantsLayer=true;errorLabel.isHidden=true;errorLabel.textColor = .secondaryLabelColor
        if nativeOnly {let view=NativeMarkdownView(frame:.zero);native=view;addSubview(view)}
        else if let root=Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview"),FileManager.default.fileExists(atPath:root.appendingPathComponent("index.html").path) {
            let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent();config.preferences.javaScriptCanOpenWindowsAutomatically=false
            let resources=MarkdownResources(root:root);config.setURLSchemeHandler(resources,forURLScheme:"orkhon-preview");config.setURLSchemeHandler(resources,forURLScheme:"orkhon-document")
            let view=WKWebView(frame:.zero,configuration:config);web=view;view.navigationDelegate=self;addSubview(view)
            view.setValue(false,forKey:"drawsBackground");view.setAccessibilityLabel("Markdown preview")
            view.load(URLRequest(url:URL(string:"orkhon-preview://bundle/index.html")!))
        } else {showError("Markdown preview resources are missing. Reinstall Orkhon Code to repair them.")}
        addSubview(errorLabel)
    }
    required init?(coder:NSCoder) {fatalError("Use init(nativeOnly:)")}
    override func layout() {super.layout();web?.frame=bounds;native?.frame=bounds;errorLabel.frame=NSRect(x:24,y:max(0,bounds.height-90),width:max(0,bounds.width-48),height:66)}
    func applyTheme(_ value:Theme) {theme=value;layer?.backgroundColor=value.background.cgColor;native?.applyTheme(value)}
    func render(_ text:String,url:URL?,documentID:String) {
        guard text.utf8.count<=5*1024*1024 else {pending=nil;web?.isHidden=true;showError("This document exceeds the 5 MB preview limit. Choose Source to view the complete file.");return}
        errorLabel.isHidden=true;web?.isHidden=false
        if let native {native.render(text);return}
        pending=(text,url,documentID);renderLatest()
    }
    private func renderLatest() {
        guard ready,!rendering,let web,let (text,url,documentID)=pending else{return}
        pending=nil;rendering=true
        func hex(_ value:UInt32)->String {String(format:"#%06x",value)}
        let colors:[String:Any]=["dark":theme.dark,"background":hex(theme.bg),"foreground":hex(theme.fg),"muted":hex(theme.muted),"accent":hex(theme.accent),"panel":hex(theme.panel),"line":hex(theme.selection)]
        var base=""
        if let url,url.isFileURL {var components=URLComponents();components.scheme="orkhon-document";components.host="local";components.path=url.deletingLastPathComponent().path+"/";base=components.string ?? ""}
        web.callAsyncJavaScript("return await window.orkhon.render(source, theme, base, documentID)",arguments:["source":text,"theme":colors,"base":base,"documentID":documentID],in:nil,in:.page) { [weak self] result in
            guard let self else{return};self.rendering=false
            if case .failure(let error)=result {self.showError("Preview could not be rendered: "+error.localizedDescription)}
            self.renderLatest()
        }
    }
    private func showError(_ message:String) {errorLabel.stringValue=message;errorLabel.isHidden=false}
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {ready=true;renderLatest()}
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {showError("Preview could not be loaded: "+error.localizedDescription)}
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) {ready=false;rendering=false;showError("Preview stopped. Switch to Source and back to reload it.");webView.reload()}
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
        guard let url=action.request.url else {decisionHandler(.cancel);return}
        if url.scheme == "orkhon-preview",url.host == "bundle",url.path == "/index.html" {decisionHandler(.allow);return}
        if action.navigationType == .linkActivated {
            if url.scheme == "orkhon-document",url.host == "local" {onOpen?(URL(fileURLWithPath:url.path))}
            else if ["http","https","mailto"].contains(url.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(url)}
        }
        decisionHandler(.cancel)
    }
}
