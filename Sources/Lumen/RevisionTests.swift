import AppKit
import WebKit
import LumenCore

extension EditorWindowController {
    func runRevisionTests() async {
        if ProcessInfo.processInfo.environment["ORKHON_TEST_REMOTE_ONLY"]=="1" {
            finishRevisionTests(await runRemoteEventTests());return
        }
        var results:[String:Bool]=[:]
        func check(_ label:String,_ value:Bool) {results[label]=value;print("\(value ? "PASS":"FAIL"): \(label)")}
        func pause(_ seconds:Double=0.15) async {try? await Task.sleep(nanoseconds:UInt64(seconds*1e9))}
        func wait(_ predicate:()->Bool) async {for _ in 0..<400 {if predicate(){return};await pause(0.05)}}
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
            check("Side-by-side opens at equal widths",abs(previewDeck.source.bounds.width-previewDeck.preview.bounds.width)<2)
            let icons=previewDeck.toolbar.subviews.compactMap{$0 as? PreviewIconButton}
            check("Preview uses two compact circular icon buttons",icons.count==2 && icons.allSatisfy{$0.frame.width==28 && $0.frame.height==28 && $0.image != nil})
            for ratio:CGFloat in [0.25,0.75] {
                previewDeck.split.setPosition((previewDeck.split.bounds.width-1)*ratio,ofDividerAt:0);root.layoutSubtreeIfNeeded();await pause(0.05)
                check("Source follows divider at \(ratio)",abs(md.editor.frame.width-previewDeck.source.bounds.width)<1 && md.editor.frame.minX==0)
                check("Renderer follows divider at \(ratio)",abs((activePane.markdown?.frame.width ?? -1)-previewDeck.preview.bounds.width)<1)
            }
            setPreviewMode(.source);setPreviewMode(.split);root.layoutSubtreeIfNeeded()
            check("Reopening side-by-side resets to half",abs(previewDeck.source.bounds.width-previewDeck.preview.bounds.width)<2)
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
            check("Conflicting row is highlighted",md.editor.send(2046,w:0,l:0) & (1<<25) != 0)
            if ProcessInfo.processInfo.environment["ORKHON_PAUSE_INLINE_TEST"]=="1" {bringToFront();md.editor.go(toLine:1);root.layoutSubtreeIfNeeded();return}
            check("Conflict controls stay inside source",activePane.externalControls != nil && !md.editor.isHidden)
            func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap{descendants($0)}}
            root.layoutSubtreeIfNeeded();await pause()
            if let controls=activePane.externalControls {
                let choose=descendants(controls).compactMap{$0 as? NSButton}.first{$0.title=="Use incoming"}
                check("Conflict has inline external choice",choose != nil);choose?.performClick(nil)
            }
            check("Per-conflict disk resolution",md.editor.text.hasPrefix("# Their heading") && md.externalChange==nil)
            func plainRows(_ d:DocumentTab,_ range:Range<Int>)->Bool {
                range.allSatisfy{d.editor.send(2046,w:$0,l:0) & ((1<<24)|(1<<25)|(1<<26)) == 0 && d.editor.send(2546,w:$0,l:0)==0}
            }
            check("Resolved conflict shows only normal source",plainRows(md,0..<3) && md.externalHighlights==nil && md.externalAnchors.isEmpty && activePane.externalControls==nil)
            markConflicts(md)
            check("Redrawing cannot restore resolved conflict colors",plainRows(md,0..<3))
            md.editor.send(2160,w:0,l:-1);md.editor.insertRecoveredText("# Their heading\n\nMy paragraph.\n")
            try "# New disk title\n\nUpdated externally.\n".write(to:one,atomically:true,encoding:.utf8)
            await wait{md.editor.text.contains("New disk title")}
            check("Independent external edits merge without conflict controls",md.externalChange==nil && md.externalHighlights != nil && md.externalAnchors.isEmpty)
            check("Accepted added lines stay highlighted",md.editor.send(2046,w:0,l:0) & (1<<24) != 0)
            check("Removed lines stay visible as annotations",md.editor.send(2546,w:0,l:0)>0)
            check("Applying independent edits preserves unsaved work",md.editor.text.contains("New disk title") && md.editor.text.contains("My paragraph") && md.isModified)
            let inlineFile=fixture.appendingPathComponent("inline.swift")
            var lines=(0..<200).map{"let line\($0) = \($0)"}
            try (lines.joined(separator:"\n")+"\n").write(to:inlineFile,atomically:true,encoding:.utf8)
            openURL(inlineFile);await wait{current?.loading==false};let inlineDoc=current!
            lines[4]="let mine = 4";lines[99]="let mineMiddle = 99";inlineDoc.editor.send(2160,w:0,l:-1);inlineDoc.editor.insertRecoveredText(lines.joined(separator:"\n")+"\n")
            lines[4]="let server = 4\nlet extra = 5";lines[99]="let serverMiddle = 99";lines[159]="let serverLast = 159"
            try (lines.joined(separator:"\n")+"\n").write(to:inlineFile,atomically:true,encoding:.utf8)
            await wait{inlineDoc.externalChange != nil}
            if let change=inlineDoc.externalChange {
                chooseExternalHunk(inlineDoc,index:0,value:1,changeID:change.id);await pause(0.4)
                check("Inline decision immediately updates only its span",inlineDoc.editor.text.contains("let extra = 5") && inlineDoc.editor.text.contains("serverLast") && inlineDoc.externalChange?.remainingCount==1)
                check("Partial decision survives watcher notifications",inlineDoc.externalChange?.id==change.id)
                check("Resolved span clears colors and discarded text immediately",plainRows(inlineDoc,0..<8) && inlineDoc.externalAnchors.count==1)
                check("Unresolved span keeps its conflict highlight",inlineDoc.editor.send(2046,w:100,l:0) & (1<<25) != 0)
                inlineDoc.editor.go(toLine:101);root.layoutSubtreeIfNeeded();await pause(0.3);root.layoutSubtreeIfNeeded()
                let visibleButtons=activePane.externalControls.map{descendants($0).compactMap{$0 as? NSButton}} ?? []
                check("Inline controls follow scrolling and changed line offsets",visibleButtons.contains{$0.title=="Keep current"})
                chooseExternalHunk(inlineDoc,index:1,value:0,changeID:change.id)
                check("Final inline decision preserves an ignored external change",inlineDoc.externalChange==nil && inlineDoc.editor.text.contains("let mineMiddle = 99") && inlineDoc.editor.text.contains("serverLast") && inlineDoc.isModified)
                check("Both resolved spans remain normal after final choice",plainRows(inlineDoc,0..<8) && plainRows(inlineDoc,98..<103) && inlineDoc.externalAnchors.isEmpty && activePane.externalControls==nil)
                inlineDoc.editor.command(2176)
                check("Undo reverses inline external replacement",inlineDoc.editor.text.contains("let mine = 4") && !inlineDoc.editor.text.contains("let extra = 5"))
            } else {check("Inline multi-span fixture detected external change",false)}
            // Cover each explicit choice, including empty replacements and EOF.
            for (name,base,mine,disk,choice,expected) in [
                ("keep current","top\nold\nend\n","top\nmine\nend\n","top\ntheirs\nextra\nend\n",0,"top\nmine\nend\n"),
                ("use incoming","top\nold\nend\n","top\nmine\nend\n","top\ntheirs\nextra\nend\n",1,"top\ntheirs\nextra\nend\n"),
                ("keep both","top\nold\nend\n","top\nmine\nend\n","top\ntheirs\nextra\nend\n",2,"top\nmine\ntheirs\nextra\nend\n"),
                ("accept removal","top\nold\nend\n","top\nmine\nend\n","top\nend\n",1,"top\nend\n"),
                ("EOF without newline","top\nold","top\nmine","top\ntheirs",1,"top\ntheirs")
            ] {
                newDocument(nil);let d=current!
                d.format=try DocumentStorage.decode(Data(base.utf8));d.editor.text=base;d.editor.markSaved()
                d.editor.send(2160,w:0,l:-1);d.editor.insertRecoveredText(mine)
                let file=try DocumentStorage.decode(Data(disk.utf8))
                let merge=try ExternalMerge.compare(base:base,mine:mine,disk:disk)
                receiveExternalFile(file,for:d,local:mine,modified:true,merge:.success(merge))
                if let change=d.externalChange,change.remainingConflicts==1 {
                    chooseExternalHunk(d,index:0,value:choice,changeID:change.id)
                    check("Resolved \(name) retains exact accepted content",d.editor.text==expected)
                    check("Resolved \(name) removes colors and ghost rows",plainRows(d,0..<d.editor.send(2154,w:0,l:0)) && d.externalHighlights==nil && d.externalAnchors.isEmpty && activePane.externalControls==nil)
                } else {check("Resolved \(name) conflict fixture",false)}
            }
            let merge=try ExternalMerge.compare(base:"a\nb\nc\n",mine:"a\nlocal\nc\n",disk:"a\nremote\nc\n")
            check("Three-way parser keeps base markers out of resolved text",merge.resolved([0:0])=="a\nlocal\nc\n" && merge.resolved([0:1])=="a\nremote\nc\n")
            let noNewline=try ExternalMerge.compare(base:"a",mine:"b",disk:"c")
            check("Conflict choices preserve missing final newline",noNewline.resolved([0:0])=="b" && noNewline.resolved([0:1])=="c")
            let choices=FileAssociations.choices()
            check("File defaults catalog cannot be empty",choices.count>=20)
            check("File defaults exclude HTML and ambiguous extensions",!choices.flatMap(\.extensions).contains{"html htm mts m2ts ts svg".split(separator:" ").map(String.init).contains($0)})
            check("Every enabled file group satisfies safety policy",choices.filter(\.eligible).allSatisfy{AssociationPolicy.eligible(extensions:($0.type.tags[.filenameExtension] ?? [])+$0.extensions,isSource:true)})
            let config=fixture.appendingPathComponent("ssh-config")
            try "Host production staging\n HostName example.invalid\nHost *.internal !excluded\n".write(to:config,atomically:true,encoding:.utf8)
            check("SSH profiles list literal aliases without wildcard hosts",SSHProfiles.aliases(config:config)==["production","staging"])
            let local=try RemoteWorkspace(host:"local-test",directory:fixture.path,localTest:true,port:2222)
            try local.connect(askpass:fixture)
            let canonical=URL(fileURLWithPath:try local.canonicalDirectory(fixture.path)).resolvingSymlinksInPath()
            check("SSH connects before selecting remote folder",canonical==fixture.resolvingSymlinksInPath())
            other.remote=local
            let remoteFile=fixture.appendingPathComponent("remote.md")
            try "one\ntwo\nthree\n".write(to:remoteFile,atomically:true,encoding:.utf8)
            other.openRemoteFile(remoteFile.path);await wait{other.current?.loading==false};let remoteDoc=other.current!
            await wait{other.remoteMonitor.eventDriven}
            check("Remote document starts automatic event monitoring",other.remoteMonitor.eventDriven && other.remotePollTimer==nil)
            try "disk\ntwo\nthree\n".write(to:remoteFile,atomically:true,encoding:.utf8)
            await wait{remoteDoc.editor.text.hasPrefix("disk")}
            check("Remote events update clean buffer automatically",remoteDoc.editor.text.hasPrefix("disk") && !remoteDoc.isModified)
            remoteDoc.editor.send(2160,w:0,l:-1);remoteDoc.editor.insertRecoveredText("my edit\ntwo\nthree\n")
            try "their edit\ntwo\nthree\n".write(to:remoteFile,atomically:true,encoding:.utf8)
            await wait{remoteDoc.externalChange != nil}
            check("Remote events open full conflict review",remoteDoc.editor.text.hasPrefix("my edit") && remoteDoc.externalChange?.merge?.conflicts.count==1 && !remoteDoc.editor.isHidden && other.activePane.externalControls != nil)
            if let change=remoteDoc.externalChange {other.chooseExternalHunk(remoteDoc,index:0,value:0,changeID:change.id)}
            check("Remote resolution adopts new disk baseline",remoteDoc.format?.text.hasPrefix("their edit")==true && remoteDoc.isModified)
            check("Remote resolved save succeeds",other.saveDocument(remoteDoc,asNew:false))
            check("Remote saved bytes match chosen version",try String(contentsOf:remoteFile,encoding:.utf8)=="my edit\ntwo\nthree\n")
            remoteDoc.editor.send(2160,w:0,l:-1);remoteDoc.editor.insertRecoveredText("new local\ntwo\nthree\n")
            other.remoteMonitor.stop();other.remoteWorkspaceRefresh.cancel();other.remotePollTimer?.invalidate();other.remotePollTimer=nil;await wait{!other.remotePollInFlight}
            try "new server\ntwo\nthree\n".write(to:remoteFile,atomically:true,encoding:.utf8)
            check("Remote save rejects concurrent external write",!other.saveDocument(remoteDoc,asNew:false))
            await wait{remoteDoc.externalChange != nil}
            check("Save conflict opens resolution instead of warning",other.activePane.externalControls != nil && remoteDoc.externalChange?.merge?.conflicts.count==1)
            let stale=remoteDoc.externalChange!
            try "latest server\ntwo\nthree\n".write(to:remoteFile,atomically:true,encoding:.utf8);other.checkRemoteChanges(force:true)
            await wait{remoteDoc.externalChange?.id != stale.id}
            other.acceptExternalChange(remoteDoc,text:stale.file.text,change:stale)
            check("Stale review cannot replace a newer external change",remoteDoc.editor.text.hasPrefix("new local") && remoteDoc.externalChange?.file.text.hasPrefix("latest server")==true)
            try remoteDoc.format!.originalData.write(to:remoteFile);other.checkRemoteChanges(force:true)
            await wait{remoteDoc.externalChange==nil}
            check("Server reverting to baseline clears obsolete review",remoteDoc.externalChange==nil && remoteDoc.editor.text.hasPrefix("new local"))
            other.remoteMonitor.stop();other.remoteWorkspaceRefresh.cancel();other.remotePollTimer?.invalidate();other.remotePollTimer=nil;other.remote=nil;local.disconnect()
            if let path=ProcessInfo.processInfo.environment["ORKHON_MARKDOWN_FIXTURE"] {
                let sample=fixture.appendingPathComponent("a/deep/ARCHITECTURE.md")
                try FileManager.default.copyItem(at:URL(fileURLWithPath:path),to:sample)
                manualWorkspace=false;openURL(sample);await wait{self.current?.loading==false}
                setPreviewMode(.preview);root.layoutSubtreeIfNeeded();await pause(0.3)
                check("Reported Markdown document opens and renders",current?.editor.text.isEmpty==false && activePane.markdown != nil)
                for index in 0..<20 {selectDocument(index.isMultiple(of:2) ? documents.firstIndex{$0===md}!:documents.count-1);await pause(0.01)}
                check("Repeated Markdown tab switching survives tree refresh",documents.contains{$0.url==sample})
            }
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
        results.merge(await runWorkspaceMonitorTests()) {_,new in new}
        results.merge(await runMarkdownPreviewTests()) {_,new in new}
        results.merge(await runAssociationSetupTests()) {_,new in new}
        finishRevisionTests(results)
    }
    private func finishRevisionTests(_ results:[String:Bool]) {
        let failures=results.filter{!$0.value}.map(\.key).sorted()
        if let path=ProcessInfo.processInfo.environment["LUMEN_TEST_RESULTS"],let data=try? JSONSerialization.data(withJSONObject:["checks":results,"failures":failures],options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:path))}
        for controller in coordinator?.windows ?? [self] {for d in controller.documents {d.baselineChanged=false;d.editor.markSaved()}}
        NSApp.terminate(nil)
    }
}
