import AppKit
import WebKit

extension EditorWindowController {
    /// Real SSH, using a caller-provisioned disposable localhost container/key.
    /// Never consults a user's SSH profile, agent, key or known-hosts file.
    func runRemoteEventTests() async -> [String:Bool] {
        var results:[String:Bool]=[:]
        func check(_ name:String,_ value:Bool) {results["SSH events: "+name]=value;print("\(value ? "PASS":"FAIL"): SSH events: \(name)")}
        func pause(_ seconds:Double=0.05) async {try? await Task.sleep(nanoseconds:UInt64(seconds*1e9))}
        func wait(_ predicate:()->Bool) async {for _ in 0..<240 {if predicate(){return};await pause()}}
        func until(_ web:WKWebView,_ expression:String) async -> Bool {
            for _ in 0..<240 {if (try? await web.evaluateJavaScript(expression)) as? Bool==true{return true};await pause()}
            return false
        }
        let env=ProcessInfo.processInfo.environment
        guard let port=env["ORKHON_TEST_SSH_PORT"].flatMap(Int.init),let key=env["ORKHON_TEST_SSH_KEY"],let controller=coordinator?.newWindow() else{return ["SSH events: fixture configured":false]}
        do {
            let connection=try RemoteWorkspace(host:"root@127.0.0.1",directory:"/preview-stress",port:port)
            let master=Process();master.executableURL=URL(fileURLWithPath:"/usr/bin/ssh")
            master.arguments=["-M","-N","-F","/dev/null","-i",key,"-p",String(port),"-o","BatchMode=yes","-o","IdentitiesOnly=yes","-o","UserKnownHostsFile="+connection.cacheURL.appendingPathComponent("known_hosts").path,"-o","StrictHostKeyChecking=accept-new","-o","ControlPath="+connection.controlPath,"--",connection.host]
            let log=connection.cacheURL.appendingPathComponent("test-handshake.log")
            FileManager.default.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600])
            let errors=try FileHandle(forWritingTo:log);defer{try? errors.close()}
            master.standardInput=FileHandle.nullDevice;master.standardOutput=FileHandle.nullDevice;master.standardError=errors
            try master.run()
            defer {
                controller.remoteMonitor.stop();controller.remoteWorkspaceRefresh.cancel();controller.remotePollTimer?.invalidate();controller.remote=nil;connection.disconnect()
                if master.isRunning {master.terminate()}
            }
            await wait{connection.ready || !master.isRunning};guard connection.ready else{throw RemoteFailure(message:"Local test SSH handshake failed: "+((try? String(contentsOf:log,encoding:.utf8)) ?? ""))}
            func python(_ source:String) async throws {
                _ = try await Task.detached {try connection.run("python3 -c "+RemoteWorkspace.quote(source))}.value
            }
            try await python("""
            from pathlib import Path
            root=Path('/preview-stress');(root/'assets').mkdir(parents=True,exist_ok=True)
            (root/'assets'/'source.js').write_text('window.sequence=0;')
            (root/'assets'/'style.css').write_text('body {color:rgb(1,2,3)}')
            (root/'index.html').write_text("<html><head><link rel='stylesheet' href='assets/style.css'><script src='assets/source.js'></script></head><body>Initial</body></html>")
            """)
            controller.remote=connection;controller.ensureRemoteTree();controller.remoteTree?.setRoot(connection.directory);controller.openRemoteFile("/preview-stress/index.html")
            await wait{controller.current?.loading==false && controller.remoteMonitor.eventDriven}
            check("real SSH stream ready without polling",controller.remoteMonitor.eventDriven && controller.remotePollTimer==nil)
            guard let doc=controller.current else{throw RemoteFailure(message:"Remote fixture did not open")}
            controller.setPreviewMode(.split)
            guard let web=controller.activePane.html?.web else{throw RemoteFailure(message:"Remote HTML preview missing")}
            check("relative assets cross real SSH",await until(web,"window.sequence===0 && getComputedStyle(document.body).color==='rgb(1, 2, 3)'"))
            doc.editor.send(2160,w:0,l:-1);doc.editor.insertRecoveredText(doc.editor.text.replacingOccurrences(of:"Initial",with:"Unsaved preview"))
            check("unsaved source previews over SSH",await until(web,"document.body.textContent==='Unsaved preview'"))
            let started=ProcessInfo.processInfo.systemUptime
            var heartbeats=0
            let heartbeat=Timer(timeInterval:0.02,repeats:true) {_ in Task { @MainActor in heartbeats+=1 }}
            RunLoop.main.add(heartbeat,forMode:.common)
            try await python("""
            from pathlib import Path
            import os,time
            root=Path('/preview-stress')
            for i in range(1200):
              folder=root/('group-'+str(i%100));folder.mkdir(exist_ok=True)
              tmp=folder/'temporary';tmp.write_bytes(bytes([i%256])*64);os.replace(tmp,folder/(str(i)+'.anything'))
              (root/'assets'/'source.js').write_text('window.sequence='+str(i+1)+';')
              if i%100==0: time.sleep(.15)
            (root/'assets'/'style.css').write_text('body {color:rgb(40,50,60)}')
            """)
            check("burst finishes with latest JS and CSS",await until(web,"window.sequence===1200 && getComputedStyle(document.body).color==='rgb(40, 50, 60)'"))
            heartbeat.invalidate();let elapsed=ProcessInfo.processInfo.systemUptime-started
            check("UI continues servicing events during SSH burst",Double(heartbeats)>elapsed*15)
            let unsavedVisible=await until(web,"document.body.textContent==='Unsaved preview'")
            check("burst preserves unsaved source and preview",doc.isModified && doc.editor.text.contains("Unsaved preview") && unsavedVisible)
            // Kill only this container's watcher Python processes, not sshd or the
            // main connection. Reconnection must establish a fresh baseline.
            try await python("""
            import os,signal
            for value in os.listdir('/proc'):
              if not value.isdigit() or int(value)==os.getpid(): continue
              try:
                args=open('/proc/'+value+'/cmdline','rb').read().split(b'\\0')
                if args[0].endswith(b'python3') and len(args)>3 and b'Orkhon SSH event helper' in args[3]: os.kill(int(value),signal.SIGTERM)
              except (OSError,ProcessLookupError): pass
            """)
            await wait{!controller.remoteMonitor.eventDriven}
            check("lost stream enables bounded reconciliation",!controller.remoteMonitor.eventDriven && controller.remotePollTimer != nil)
            try await python("from pathlib import Path;Path('/preview-stress/assets/source.js').write_text('window.sequence=9000;')")
            await wait{controller.remoteMonitor.eventDriven}
            check("stream reconnects and disables fallback",controller.remoteMonitor.eventDriven && controller.remotePollTimer==nil)
            check("changes during outage refresh after reconnect",await until(web,"window.sequence===9000"))
            try await python("""
            from pathlib import Path
            p=Path('/preview-stress/index.html');p.write_text(p.read_text().replace('Initial','External'))
            """)
            await wait{doc.externalChange != nil}
            check("external source conflict preserves local text",doc.externalChange?.remainingConflicts==1 && doc.editor.text.contains("Unsaved preview"))
            if let change=doc.externalChange,let index=change.merge?.changes.firstIndex(where:{$0.conflictIndex != nil}) {controller.chooseExternalHunk(doc,index:index,value:0,changeID:change.id)}
            check("resolved remote conflict returns to normal content",doc.externalChange==nil && doc.externalAnchors.isEmpty && doc.editor.text.contains("Unsaved preview"))
        } catch {print(error);check("fixtures complete",false)}
        return results
    }
}
