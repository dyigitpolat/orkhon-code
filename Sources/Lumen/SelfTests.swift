import AppKit
import EditorBridge
import LumenCore
extension EditorWindowController {
    func recordStartupTestIfRequested() {
        guard let path=ProcessInfo.processInfo.environment["ORKHON_STARTUP_TEST_RESULT"] else{return}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
            let result:[String:Any]=["welcomeSelected":self.current?.isWelcome==true,"markdownPreview":self.current?.previewingMarkdown==true,"setupVisible":self.window.attachedSheet != nil,"restoredFileCount":self.documents.filter{$0.url != nil}.count,"tabs":self.documents.map{$0.title},"fileGroups":FileAssociations.choices().map{["extensions":$0.extensions,"eligible":$0.eligible,"previous":$0.previous ?? ""] as [String:Any]}]
            if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:path))}
            if let sheet=self.window.attachedSheet {self.window.endSheet(sheet);sheet.orderOut(nil)}
            NSApp.terminate(nil)
        }
    }
    func runEditorSelfTests() {
        var results:[String:Any]=[:],failures:[String]=[]
        func check(_ name:String,_ condition:Bool){results[name]=condition;if !condition{failures.append(name)}}
        let e=LMEditorView(frame:NSRect(x:0,y:0,width:800,height:600));editorSurface.addSubview(e)
        e.text="alpha βeta\nsecond alpha\n";e.markSaved()
        check("UTF-8 roundtrip",e.text == "alpha βeta\nsecond alpha\n")
        check("clean savepoint",!e.modified)
        e.go(toLine:2);check("line navigation",e.currentLine==2)
        check("find",e.find("alpha",backwards:false,matchCase:true,regex:false,wholeWord:true))
        let n=e.replace("alpha",with:"omega",all:true,matchCase:true,regex:false,wholeWord:true)
        check("replace all",n==2 && e.text=="omega βeta\nsecond omega\n")
        e.command(2176);check("undo transaction",e.text=="alpha βeta\nsecond alpha\n")
        e.command(2011);check("redo",e.text.contains("omega"))
        e.text="abc 123 abc 456";let rx=e.replace("([0-9]+)",with:"[\\1]",all:true,matchCase:true,regex:true,wholeWord:false)
        check("regex capture replacement",rx==2 && e.text=="abc [123] abc [456]")
        check("invalid regex",e.replace("[",with:"x",all:true,matchCase:true,regex:true,wholeWord:false)<0)
        e.text="a\nb\n";let zero=e.replace("^",with:">",all:true,matchCase:true,regex:true,wholeWord:false)
        check("zero length regex terminates",zero>=2 && zero<=3)
        e.text="line one\nline two\n";e.go(toLine:1);e.toggleComment("//");check("comment",e.text.hasPrefix("//"));e.toggleComment("//");check("uncomment",e.text=="line one\nline two\n")
        e.wordWrap=true;check("wrap",e.wordWrap);e.wordWrap=false
        let languages=LanguageRegistry.shared.languages,available=Set(LMEditorView.availableLexers())
        check("language registry loaded",languages.count>=80)
        check("all lexers available",languages.allSatisfy{available.contains($0.lexer)})
        var counts:[String:Int]=[:]
        for (ext,code) in [("swift","import Foundation\nlet answer = 42 // comment\n"),("py","def greet(name):\n    return 'hello' # comment\n"),("js","const answer = 42; // comment\n"),("rs","fn main() { let n = 42; }\n"),("json","{\"name\": true, \"n\": 42}"),("html","<div class=\"greeting\">Hello</div>"),("css","body { color: red; }"),("toml","[section]\nvalue = 42\n"),("MD","# Heading\n\n**Bold** and `code`.\n")] {
            if let l=LanguageRegistry.shared.language(for:URL(fileURLWithPath:"sample."+ext),text:code) {
                e.text=code;e.setLexer(l.lexer,keywords:l.keywords,properties:l.properties);e.send(4003,w:0,l:-1)
                counts[ext]=(0..<code.utf8.count).filter{e.send(2010,w:$0,l:0)>0}.count
                check("highlight \(ext)",(counts[ext] ?? 0)>0)
                let normal=e.send(2481,w:32,l:0)
                check("visible token color \(ext)",(0..<code.utf8.count).contains{e.send(2481,w:e.send(2010,w:$0,l:0),l:0) != normal})
            } else {check("language \(ext)",false)}
        }
        var unthemed:[String]=[]
        for language in languages where language.lexer != "null" && language.lexer != "indent" {
            e.setLexer(language.lexer,keywords:language.keywords,properties:language.properties)
            let normal=e.send(2481,w:32,l:0)
            if !(0..<256).contains(where:{($0<32 || $0>39) && e.send(2481,w:$0,l:0) != normal}) {unthemed.append(language.name)}
        }
        results["unthemedProfiles"]=unthemed;check("all syntax profiles have theme colors",unthemed.isEmpty)
        if let parsed=try? AttributedString(markdown:"# Title\n\n**Bold** and `code`\n\n- First\n- Second") {
            let rendered=MarkdownRenderer.render(parsed,theme:theme)
            check("native Markdown content",rendered.string.contains("Title") && rendered.string.contains("Bold") && rendered.string.contains("•  First"))
            check("native Markdown heading style",(rendered.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.pointSize ?? 0 > 20)
        }
        for _ in 0..<16 {newDocument(nil)}
        root.layoutSubtreeIfNeeded();revealSelectedTab()
        let activeRect=tabStack.arrangedSubviews[selected].frame
        check("opened tab scrolled into view",tabScroll.documentVisibleRect.intersects(activeRect) && tabScroll.documentVisibleRect.maxX>=activeRect.maxX-1)
        check("overflow controls visible",tabBack.isEnabled && !tabForward.isEnabled && allTabs.title==String(documents.count))
        showFind(nil);check("unified find and replace",showFind && showReplace && !replaceInput.isHidden)
        check("find field receives keyboard focus",findField.currentEditor() != nil && findField.isEditable)
        if let editor=findField.currentEditor() {editor.insertText("search input");window.makeFirstResponder(nil)}
        check("find field accepts input",findField.stringValue=="search input")
        window.makeFirstResponder(replaceField)
        check("replace field receives keyboard focus",replaceField.currentEditor() != nil && replaceField.isEditable)
        if let editor=replaceField.currentEditor() {editor.insertText("replacement");window.makeFirstResponder(nil)}
        check("replace field accepts input",replaceField.stringValue=="replacement")
        if let first=documents.first,let last=documents.last {
            let pin=NSMenuItem();pin.representedObject=last;pinTab(pin)
            check("pin retains selected document",documents.first===last && current===last && last.pinned)
            let close=NSMenuItem();close.representedObject=first;closeOtherTabs(close)
            check("close others preserves pinned tab",documents.count==2 && documents.contains{$0===last} && documents.contains{$0===first})
            closeTabsToRight(pin)
            check("close to right removes unpinned tabs",documents.count==1 && documents.first===last)
        }
        results["styledByteCounts"]=counts
        e.setLexer("null",keywords:[],properties:[:]);let big=String(repeating:"A short line of Unicode text — 0123456789\n",count:200000)
        let start=DispatchTime.now().uptimeNanoseconds;e.text=big
        results["largeDocumentBytes"]=big.utf8.count;results["largeDocumentLoadMilliseconds"]=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
        check("large document intact",e.text==big)
        results["lexerCount"]=available.count;results["profileCount"]=languages.count;results["failures"]=failures
        e.removeFromSuperview()
        if let path=ProcessInfo.processInfo.environment["LUMEN_TEST_RESULTS"],let data=try? JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]){try? data.write(to:URL(fileURLWithPath:path))}
        print(results)
        exit(failures.isEmpty ? 0:1)
    }
}
