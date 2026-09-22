import AppKit
import WebKit
import LumenCore

extension EditorWindowController {
    func runRevisionTests() async {
        var results:[String:Bool]=[:]
        func check(_ label:String,_ value:Bool) {results[label]=value;print("\(value ? "PASS":"FAIL"): \(label)")}
        func pause(_ seconds:Double=0.15) async {try? await Task.sleep(nanoseconds:UInt64(seconds*1e9))}
        func wait(_ predicate:()->Bool) async {for _ in 0..<100 {if predicate(){return};await pause(0.05)}}
        let fixture=URL(fileURLWithPath:ProcessInfo.processInfo.environment["ORKHON_TEST_DATA"]!).appendingPathComponent("fixtures")
        do {
            try FileManager.default.createDirectory(at:fixture.appendingPathComponent("a/deep"),withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:fixture.appendingPathComponent("b"),withIntermediateDirectories:true)
            let one=fixture.appendingPathComponent("a/deep/one.md"),two=fixture.appendingPathComponent("b/two.swift")
            try "# Hello\n\nInitial Markdown.\n".write(to:one,atomically:true,encoding:.utf8)
            try "let value = 1\n".write(to:two,atomically:true,encoding:.utf8)
            openURL(one);await wait{self.current?.loading==false};let md=current!
            check("Source preview control always visible",!previewDeck.toolbar.isHidden)
            setPreviewMode(.split);root.layoutSubtreeIfNeeded();await pause();root.layoutSubtreeIfNeeded()
            check("Side-by-side preview exposes editor and renderer",!previewDeck.source.isHidden && !previewDeck.preview.isHidden && previewDeck.source.bounds.width>150 && previewDeck.preview.bounds.width>150)
            openURL(two);await wait{self.current?.loading==false};let swift=current!
            await pause(0.4)
            check("Automatic tree common parent",workspaceURL?.path==fixture.path)
            check("Tree opens all file ancestor paths",tree?.expandedOpenPaths.contains(one.deletingLastPathComponent().path)==true)
            check("Tree marks open files",tree?.highlightedOpenPaths==Set([one.path,two.path]))
            splitEditor(with:md,onLeft:false);root.layoutSubtreeIfNeeded();await pause();root.layoutSubtreeIfNeeded()
            check("Two document panes",editorIsSplit && firstPane.document === swift && secondPane.document === md && firstPane.bounds.width>150 && secondPane.bounds.width>150)
            check("Document split disables side-by-side preview",md.previewMode == .source)
            setPreviewMode(.split);check("Side-by-side request rejected during document split",md.previewMode == .source)
            setPreviewMode(.preview);check("Full preview works inside a document pane",md.previewMode == .preview)
            collapseEditorSplit(keeping:md);check("Closing a pane retains both tabs",!editorIsSplit && documents.contains{$0===swift} && documents.contains{$0===md})
            splitEditor(with:md,onLeft:true);check("Active tab can be split alongside another open tab",editorIsSplit && firstPane.document === md && secondPane.document === swift)
            collapseEditorSplit(keeping:md)
            setFolder(fixture.appendingPathComponent("a"));selectDocument(documents.firstIndex{$0===swift}!)
            check("Manual workspace remains fixed",manualWorkspace && workspaceURL==fixture.appendingPathComponent("a"))
            swift.editor.send(2160,w:0,l:-1);swift.editor.insertRecoveredText("let value = 2\n")
            let editorIdentity=swift.editor;moveToNewWindow(swift)
            let other=coordinator!.active!
            check("Moved tab preserves editor and unsaved text",other.current?.editor === editorIdentity && other.current?.isModified==true && other.current?.editor.text=="let value = 2\n")
            other.current?.editor.command(2176)
            check("Moved tab preserves undo history",other.current?.editor.text=="let value = 1\n")
            check("Window state is independent",other !== self && other.workspaceURL != self.workspaceURL)
            bringToFront();selectDocument(documents.firstIndex{$0===md}!);setPreviewMode(.source)
            try "# Disk update\n\nUpdated externally.\n".write(to:one,atomically:true,encoding:.utf8)
            await wait{md.editor.text.contains("Disk update")}
            check("Atomic external write refreshes clean buffer automatically",md.editor.text.contains("Disk update") && !md.isModified)
            md.editor.send(2160,w:0,l:-1);md.editor.insertRecoveredText("# My heading\n\nUpdated externally.\n")
            try "# Their heading\n\nUpdated externally.\n".write(to:one,atomically:true,encoding:.utf8)
            await wait{md.externalChange != nil}
            check("Conflicting disk write preserves local text",md.editor.text.contains("My heading") && md.externalChange?.merge?.conflicts.count==1)
            check("Conflicting row is highlighted",md.editor.send(2046,w:0,l:0) & (1<<26) != 0)
            if let change=md.externalChange,let resolved=change.merge?.resolved([0:1]) {acceptExternalChange(md,text:resolved,change:change)}
            check("Per-conflict disk resolution",md.editor.text.hasPrefix("# Their heading") && md.externalChange==nil)
            md.editor.send(2160,w:0,l:-1);md.editor.insertRecoveredText("# Their heading\n\nMy paragraph.\n")
            try "# New disk title\n\nUpdated externally.\n".write(to:one,atomically:true,encoding:.utf8)
            await wait{md.editor.text.contains("New disk title")}
            check("Independent external edits merge without discarding unsaved changes",md.editor.text.contains("New disk title") && md.editor.text.contains("My paragraph") && md.isModified)
            let merge=try ExternalMerge.compare(base:"a\nb\nc\n",mine:"a\nlocal\nc\n",disk:"a\nremote\nc\n")
            check("Three-way parser keeps base markers out of resolved text",merge.resolved([0:0])=="a\nlocal\nc\n" && merge.resolved([0:1])=="a\nremote\nc\n")
            let noNewline=try ExternalMerge.compare(base:"a",mine:"b",disk:"c")
            check("Conflict choices preserve missing final newline",noNewline.resolved([0:0])=="b" && noNewline.resolved([0:1])=="c")
            let choices=FileAssociations.choices()
            check("File defaults catalog cannot be empty",choices.count>=20)
            check("File defaults exclude HTML and ambiguous extensions",!choices.flatMap(\.extensions).contains{"html mts ts txt svg xml".split(separator:" ").map(String.init).contains($0)})
            check("Every enabled file group satisfies safety policy",choices.filter(\.eligible).allSatisfy{AssociationPolicy.eligible(extensions:($0.type.tags[.filenameExtension] ?? [])+$0.extensions,isSource:true,current:$0.previous)})
            let config=fixture.appendingPathComponent("ssh-config")
            try "Host production staging\n HostName example.invalid\nHost *.internal !excluded\n".write(to:config,atomically:true,encoding:.utf8)
            check("SSH profiles list literal aliases without wildcard hosts",SSHProfiles.aliases(config:config)==["production","staging"])
            let local=try RemoteWorkspace(host:"local-test",directory:fixture.path,localTest:true,port:2222)
            try local.connect(askpass:fixture)
            let canonical=URL(fileURLWithPath:try local.canonicalDirectory(fixture.path)).resolvingSymlinksInPath()
            check("SSH connects before selecting remote folder",canonical==fixture.resolvingSymlinksInPath());local.disconnect()
            var fireCount=0
            let scheduler=PreviewRefresh(idle:0.08,maxDelay:0.2)
            for _ in 0..<7 {scheduler.schedule{fireCount+=1};await pause(0.04)}
            check("Preview refresh maximum delay fires during continuous edits",fireCount>=1)
            await pause(0.12);check("Preview refresh coalesces changes",fireCount<=2)
            for _ in 0..<14 {newDocument(nil)};root.layoutSubtreeIfNeeded();revealSelectedTab()
            check("Thin tab rail cannot overlay labels",!tabScroll.hasHorizontalScroller && tabScroll.contentView.frame.height<tabScroll.bounds.height)
            check("New tab fully visible after overflow",tabScroll.documentVisibleRect.maxX>=tabStack.arrangedSubviews[selected].frame.maxX-1)
            // File-origin HTML must load sibling/parent resources and execute relative JS.
            try FileManager.default.createDirectory(at:fixture.appendingPathComponent("assets"),withIntermediateDirectories:true)
            try "body { color: rgb(12, 34, 56); }".write(to:fixture.appendingPathComponent("assets/style.css"),atomically:true,encoding:.utf8)
            try "window.relativeAsset=42;".write(to:fixture.appendingPathComponent("assets/script.js"),atomically:true,encoding:.utf8)
            let html=fixture.appendingPathComponent("b/index.html")
            let assetURL=ProcessInfo.processInfo.environment["ORKHON_TEST_HTTP_ASSET"]
            let networkScript=assetURL.map{"<script src='"+$0+"'></script>"} ?? ""
            let htmlText="<!doctype html><html><head><link rel='stylesheet' href='../assets/style.css'><script src='../assets/script.js'></script>"+networkScript+"</head><body>Preview fixture</body></html>"
            try htmlText.write(to:html,atomically:true,encoding:.utf8);openURL(html);await wait{self.current?.loading==false};setPreviewMode(.preview);await pause(2)
            if let web=activePane.html?.web {
                if let html=activePane.html {html.layout();check("HTML layout retains finite geometry",html.subviews.allSatisfy{$0.frame.origin.x.isFinite && $0.frame.origin.y.isFinite && $0.frame.width.isFinite && $0.frame.height.isFinite})}
                let value=try? await web.evaluateJavaScript("JSON.stringify([window.relativeAsset,getComputedStyle(document.body).color])")
                check("HTML preview loads relative parent CSS and JS",value as? String == "[42,\"rgb(12, 34, 56)\"]")
                if assetURL != nil {let remote=try? await web.evaluateJavaScript("window.networkAsset");check("HTML preview loads HTTP script artifacts",(remote as? Int)==73)}
                setPreviewMode(.split);current?.editor.send(2160,w:0,l:-1);current?.editor.insertRecoveredText(htmlText.replacingOccurrences(of:"Preview fixture",with:"Live change"));await pause(1.5)
                let live=try? await web.evaluateJavaScript("JSON.stringify([window.relativeAsset,getComputedStyle(document.body).color,document.body.textContent])")
                check("Unsaved HTML retains relative assets and updates live",(live as? String)?.contains("[42,\"rgb(12, 34, 56)\",\"Live change\"]")==true)
            } else {check("Native HTML viewer exists",false)}
        } catch {print(error);check("Revision fixtures completed",false)}
        let failures=results.filter{!$0.value}.map(\.key).sorted()
        if let path=ProcessInfo.processInfo.environment["LUMEN_TEST_RESULTS"],let data=try? JSONSerialization.data(withJSONObject:["checks":results,"failures":failures],options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:path))}
        for controller in coordinator?.windows ?? [self] {for d in controller.documents {d.baselineChanged=false;d.editor.markSaved()}}
        NSApp.terminate(nil)
    }
}
