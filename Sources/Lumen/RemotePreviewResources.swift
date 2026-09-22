import Foundation
import WebKit
import UniformTypeIdentifiers

/// Relative SSH preview resources are fetched on demand through the existing
/// authenticated, bounded transport. No recursive downloads or server web port.
final class RemotePreviewResources:NSObject,WKURLSchemeHandler {
    var connection:RemoteWorkspace?
    var origin:String?
    var document:(url:URL,text:String)?
    var imagesOnly=false
    private var active=Set<ObjectIdentifier>()
    private var operations:[ObjectIdentifier:Operation]=[:]
    private let reads:OperationQueue = {
        let queue=OperationQueue();queue.name="app.orkhon.remote-preview";queue.qualityOfService = .userInitiated;queue.maxConcurrentOperationCount=4;return queue
    }()
    func webView(_ webView:WKWebView,start task:WKURLSchemeTask) {
        let id=ObjectIdentifier(task);active.insert(id)
        guard let url=task.request.url,let connection,url.scheme=="orkhon-remote",url.host==origin,url.path.hasPrefix("/"),!url.path.contains("\0"),task.request.httpMethod==nil || task.request.httpMethod=="GET" else {
            active.remove(id);task.didFailWithError(URLError(.badURL));return
        }
        let ext=url.pathExtension.lowercased()
        if imagesOnly && !["png","jpg","jpeg","gif","webp","svg","avif","heic","tiff","bmp","ico"].contains(ext) {
            active.remove(id);task.didFailWithError(URLError(.noPermissionsToReadFile));return
        }
        let source=document.flatMap{$0.url==url ? $0.text:nil}
        let limit=imagesOnly ? 16*1024*1024:32*1024*1024
        let operation=BlockOperation();operations[id]=operation
        operation.addExecutionBlock { [weak self,weak operation] in
            guard operation?.isCancelled==false else{return}
            let result=Result {try source.map{Data($0.utf8)} ?? connection.read(url.path,limit:limit)}
            DispatchQueue.main.async { [weak self] in
                guard let self else{return};self.operations.removeValue(forKey:id)
                guard self.active.remove(id) != nil else{return}
                switch result {
                case .success(let data):
                    let types=["js":"application/javascript","mjs":"application/javascript","css":"text/css","svg":"image/svg+xml","html":"text/html","htm":"text/html","xhtml":"application/xhtml+xml","md":"text/plain"]
                    let mime=source != nil ? "text/html":types[ext] ?? UTType(filenameExtension:ext)?.preferredMIMEType ?? "application/octet-stream"
                    let response=HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":mime+(source != nil ? "; charset=utf-8":""),"Content-Length":String(data.count),"Cache-Control":"no-store"])
                    if let response {task.didReceive(response)} else {task.didReceive(URLResponse(url:url,mimeType:mime,expectedContentLength:data.count,textEncodingName:nil))}
                    task.didReceive(data);task.didFinish()
                case .failure(let error):task.didFailWithError(error)
                }
            }
        }
        reads.addOperation(operation)
    }
    func webView(_ webView:WKWebView,stop task:WKURLSchemeTask) {let id=ObjectIdentifier(task);active.remove(id);operations.removeValue(forKey:id)?.cancel()}
    deinit {reads.cancelAllOperations()}
}
