import AppKit
import WebKit

extension EditorWindowController {
    func runWorkspaceMonitorTests() async -> [String:Bool] {
        var results:[String:Bool]=[:]
        func check(_ name:String,_ value:Bool) {results["Workspace events: "+name]=value;print("\(value ? "PASS":"FAIL"): Workspace events: \(name)")}
        func pause(_ seconds:Double) async {try? await Task.sleep(nanoseconds:UInt64(seconds*1e9))}
        func wait(_ predicate:()->Bool) async {for _ in 0..<400 {if predicate(){return};await pause(0.05)}}
        func until(_ web:WKWebView,_ expression:String) async -> Bool {
            for _ in 0..<400 {if (try? await web.evaluateJavaScript(expression)) as? Bool == true{return true};await pause(0.05)}
            return false
        }
        let directory=URL(fileURLWithPath:ProcessInfo.processInfo.environment["ORKHON_TEST_DATA"]!).appendingPathComponent("event-workspace")
        guard let controller=coordinator?.newWindow() else{return ["Workspace events: test window":false]}
        defer {
            controller.fileMonitor.stop();controller.remoteMonitor.stop();controller.localWorkspaceRefresh.cancel();controller.remoteWorkspaceRefresh.cancel()
            controller.remotePollTimer?.invalidate();controller.remote?.disconnect();controller.remote=nil
        }
        do {
            let assets=directory.appendingPathComponent("nested/assets")
            try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
            let css=assets.appendingPathComponent("style.css"),js=assets.appendingPathComponent("code.js")
            try "body {color:rgb(10,20,30)}".write(to:css,atomically:true,encoding:.utf8)
            try "window.asset=41".write(to:js,atomically:true,encoding:.utf8)
            let html=directory.appendingPathComponent("index.html")
            let source="<html><head><link rel='stylesheet' href='nested/assets/style.css'><script src='nested/assets/code.js'></script></head><body>Preview</body></html>"
            try source.write(to:html,atomically:true,encoding:.utf8)
            controller.setFolder(directory);controller.openURL(html);await wait{controller.current?.loading==false}
            let doc=controller.current!
            check("source-only workspace does not create WebKit",controller.activePane.html==nil && controller.activePane.markdown==nil)
            controller.setPreviewMode(.preview)
            if let web=controller.activePane.html?.web {
                check("initial local assets load",await until(web,"window.asset===41"))
                try "body {color:rgb(40,50,60)}".write(to:css,atomically:true,encoding:.utf8)
                try "window.asset=82".write(to:js,atomically:true,encoding:.utf8)
                check("nested CSS and JS changes invalidate local preview",await until(web,"window.asset===82 && getComputedStyle(document.body).color==='rgb(40, 50, 60)'"))
                let before=doc.previewAssetRevision
                try Data([0,1,2]).write(to:assets.appendingPathComponent("arbitrary.unlisted"))
                await wait{doc.previewAssetRevision>before}
                check("unlisted binary extension triggers refresh",doc.previewAssetRevision>before)
                var pulses=0
                let timer=Timer(timeInterval:0.02,repeats:true) {_ in Task { @MainActor in pulses+=1 }}
                RunLoop.main.add(timer,forMode:.common)
                let started=ProcessInfo.processInfo.systemUptime
                try await Task.detached {
                    for i in 0..<2000 {
                        let folder=directory.appendingPathComponent("burst/"+String(i%100))
                        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                        try Data(repeating:UInt8(i%256),count:64).write(to:folder.appendingPathComponent(String(i)+".unlisted"),options:.atomic)
                        if i%20==0 {try ("window.asset="+String(i)).write(to:js,atomically:true,encoding:.utf8)}
                    }
                    try "window.asset=2000".write(to:js,atomically:true,encoding:.utf8)
                }.value
                check("local burst renders the final asset version",await until(web,"window.asset===2000"))
                timer.invalidate()
                check("UI remains responsive during local event burst",Double(pulses)>(ProcessInfo.processInfo.systemUptime-started)*15)
                controller.setPreviewMode(.source);let hiddenRevision=doc.previewAssetRevision
                try "window.asset=99".write(to:js,atomically:true,encoding:.utf8)
                await wait{doc.previewAssetRevision>hiddenRevision}
                check("hidden preview records asset invalidation",doc.previewAssetRevision>hiddenRevision)
                controller.setPreviewMode(.preview)
                check("showing hidden preview loads latest assets",await until(web,"window.asset===99"))
            } else {check("local HTML renderer",false)}
            let connection=try RemoteWorkspace(host:"local-test",directory:directory.path,localTest:true)
            controller.remote=connection;controller.ensureRemoteTree();controller.remoteTree?.setRoot(directory.path)
            controller.openRemoteFile(html.path);await wait{controller.current?.loading==false}
            await wait{controller.remoteMonitor.eventDriven}
            check("remote event stream replaces idle hash timer",controller.remoteMonitor.eventDriven && controller.remotePollTimer==nil)
            controller.setPreviewMode(.preview)
            if let web=controller.activePane.html?.web {
                check("SSH HTML loads relative CSS and JavaScript",await until(web,"window.asset===99 && getComputedStyle(document.body).color==='rgb(40, 50, 60)'"))
                try "window.asset=123".write(to:js,atomically:true,encoding:.utf8)
                check("SSH asset event reloads preview",await until(web,"window.asset===123"))
            } else {check("remote HTML renderer",false)}
            let markdown=directory.appendingPathComponent("readme.md"),svg=assets.appendingPathComponent("picture.svg")
            func image(_ width:Int)->String {"<svg xmlns='http://www.w3.org/2000/svg' width='\(width)' height='8'><rect width='\(width)' height='8' fill='green'/></svg>"}
            try image(8).write(to:svg,atomically:true,encoding:.utf8)
            try "# Remote image\n\n![image](nested/assets/picture.svg)\n".write(to:markdown,atomically:true,encoding:.utf8)
            controller.openRemoteFile(markdown.path);await wait{controller.current?.loading==false};controller.setPreviewMode(.preview)
            if let web=controller.activePane.markdown?.web {
                check("SSH Markdown resolves relative image",await until(web,"document.querySelector('article img')?.naturalWidth===8"))
                try image(19).write(to:svg,atomically:true,encoding:.utf8)
                check("SSH Markdown image changes invalidate cached image",await until(web,"document.querySelector('article img')?.naturalWidth===19"))
            } else {check("remote Markdown renderer",false)}
            // Exercise the requested bounds at their real durations. Ongoing events
            // must not postpone a refresh until a large checkout/build finishes.
            let scheduler=PreviewRefresh(idle:1,maxDelay:3)
            var times:[Double]=[];let start=ProcessInfo.processInfo.systemUptime
            for _ in 0..<9 {scheduler.schedule{times.append(ProcessInfo.processInfo.systemUptime-start)};await pause(0.45)}
            check("continuous events flush by three-second scheduling limit",times.first.map{$0>=2.9 && $0<3.6} ?? false)
            await pause(1.1)
            check("burst coalesces into bounded batches",times.count==2)
            scheduler.schedule{times.append(100)};scheduler.cancel();await pause(1.1)
            check("closed workspace cancels pending refresh",times.count==2)
            let stopped=controller.current!.previewAssetRevision
            controller.remoteMonitor.stop();controller.remoteWorkspaceRefresh.cancel()
            try image(24).write(to:svg,atomically:true,encoding:.utf8);await pause(1.4)
            check("stopping SSH watcher stops filesystem callbacks",controller.current!.previewAssetRevision==stopped)
        } catch {print(error);check("fixtures complete",false)}
        return results
    }
}
