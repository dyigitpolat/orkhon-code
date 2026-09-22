import AppKit
import WebKit

extension EditorWindowController {
    func runMarkdownPreviewTests() async -> [String:Bool] {
        var results:[String:Bool]=[:]
        func check(_ name:String,_ value:Bool) {results["Markdown: "+name]=value;print("\(value ? "PASS":"FAIL"): Markdown: \(name)")}
        let welcome=MarkdownView(nativeOnly:true)
        check("welcome has no WebKit instance",welcome.web==nil)
        let view=MarkdownView();view.frame=NSRect(x:0,y:0,width:720,height:520);root.addSubview(view);defer{view.removeFromSuperview()}
        guard let web=view.web else {check("renderer exists",false);return results}
        func evaluate(_ expression:String) async -> Bool {(try? await web.evaluateJavaScript(expression)) as? Bool == true}
        func until(_ expression:String) async -> Bool {
            for _ in 0..<200 {if await evaluate(expression) {return true};try? await Task.sleep(nanoseconds:50_000_000)}
            return false
        }
        let directory=URL(fileURLWithPath:ProcessInfo.processInfo.environment["ORKHON_TEST_DATA"]!).appendingPathComponent("markdown")
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try "<svg xmlns='http://www.w3.org/2000/svg' width='12' height='12'><rect width='12' height='12' fill='green'/></svg>".write(to:directory.appendingPathComponent("image.svg"),atomically:true,encoding:.utf8)
        } catch {check("local image fixture",false)}
        let url=directory.appendingPathComponent("example.md")
        view.applyTheme(theme)
        view.render("""
        # Preview

        | Name | Value |
        | :--- | ---: |
        | **Bold** | 42 |

        - [x] Done
        - [ ] Pending

        ~~Removed~~ and `code`.

        ```swift
        let sample = "<script>bad()</script>"
        ```

        ![Relative image](image.svg)

        <script>window.unsafeScript=true</script>
        <img src="missing.png" onerror="window.unsafeScript=true">
        <a href="javascript:window.unsafeScript=true">bad</a>
        <details><summary>Details</summary>Safe HTML</details>
        """,url:url,documentID:"fixture")
        check("first render completes",await until("!!document.documentElement.dataset.rendered"))
        check("tables and alignment",await evaluate("document.querySelectorAll('table tbody td').length===2 && getComputedStyle(document.querySelector('table th:last-child')).textAlign==='right'"))
        check("task lists",await evaluate("document.querySelectorAll('input[type=checkbox]').length===2 && document.querySelector('input').checked"))
        check("strikethrough and code fences",await evaluate("!!document.querySelector('s') && document.querySelector('pre code').textContent.includes('<script>bad()</script>')"))
        check("relative images resolve and decode",await until("document.querySelector('img').complete && document.querySelector('img').naturalWidth===12"))
        check("raw document scripts and event handlers cannot run",await evaluate("!window.unsafeScript && !document.querySelector('article script') && !document.querySelector('[onerror]') && !document.querySelector('a[href^=javascript]')"))
        check("safe details HTML",await evaluate("document.querySelector('details summary').textContent==='Details'"))
        check("math and diagrams not loaded for ordinary Markdown",await evaluate("!window.katex && !window.mermaid && !document.querySelector('[data-optional]')"))
        view.render(#"Inline $E=mc^2$ and \(a+b\)."#+"\n\n$$\n\\int_0^1 x^2 dx = \\frac{1}{3}\n$$\n\n```mermaid\nflowchart LR\n A[Source] --> B[Preview]\n```\n",url:url,documentID:"fixture")
        check("math and Mermaid render",await until("document.querySelectorAll('.katex').length>=3 && !!document.querySelector('figure svg')"))
        check("accessible MathML",await evaluate("document.querySelectorAll('math').length>=3"))
        check("display equations",await evaluate("!!document.querySelector('.katex-display')"))
        check("diagram contains expected text",await evaluate("document.querySelector('figure svg').textContent.includes('Source') && document.querySelector('figure svg').textContent.includes('Preview')"))
        let old=try? await web.evaluateJavaScript("document.querySelector('figure svg').outerHTML")
        view.render("Changed paragraph.\n\n```mermaid\nflowchart LR\n A[Source] --> B[Preview]\n```\n",url:url,documentID:"fixture")
        check("live update completes",await until("document.querySelector('article').textContent.includes('Changed paragraph') && !!document.querySelector('figure svg')"))
        let new=try? await web.evaluateJavaScript("document.querySelector('figure svg').outerHTML")
        check("unchanged diagrams reuse cached SVG",(old as? String) != nil && old as? String == new as? String)
        view.render("```mermaid\nthis is not a valid diagram\n```\n",url:url,documentID:"fixture")
        check("invalid diagram has recoverable inline error",await until("!!document.querySelector('figure .render-error')"))
        view.render("$\\href{javascript:alert(1)}{bad}$\n",url:url,documentID:"fixture")
        check("untrusted TeX cannot create script links",await until("document.querySelector('article').textContent.includes('bad') && !document.querySelector('article a[href^=javascript]')"))
        view.render("# One",url:url,documentID:"fixture");view.render("# Latest",url:url,documentID:"fixture")
        check("rapid edits show newest source",await until("document.querySelector('h1')?.textContent==='Latest'"))
        view.applyTheme(Theme.all[1]);view.render("# Daylight",url:url,documentID:"fixture")
        check("theme updates",await until("document.documentElement.style.colorScheme==='light' && document.querySelector('h1')?.textContent==='Daylight'"))
        view.render("# Recovery",url:url,documentID:"fixture")
        check("preview remains usable after rendering errors",await until("document.querySelector('h1')?.textContent==='Recovery'"))
        let choices=FileAssociations.choices()
        for ext in ["txt","json","toml","yaml","md","cpp","hpp","rs","go","jsonc","tsx"] {
            check("association catalog resolves .\(ext)",choices.contains{$0.extensions.contains(ext) && $0.eligible})
        }
        var selection=AssociationSelection(choices)
        if let json=choices.first(where:{$0.extensions.contains("json") && $0.eligible}) {
            let appGroup=choices.filter{$0.observed==json.observed}
            check("group starts All",selection.groupState(appGroup) == .on)
            selection.toggle(json)
            if appGroup.filter(\.eligible).count>1 {check("individual opt-out makes group Selective",selection.groupState(appGroup) == .mixed)}
            check("association search preserves opt-outs",!selection.matching(".json").isEmpty && !selection.selected.contains(json.type.identifier))
            selection.set(selection.matching(".json"),enabled:true)
            check("group actions select matching formats",selection.selected.contains(json.type.identifier))
            selection.set(appGroup,enabled:false)
            check("group switches Off",selection.groupState(appGroup) == .off)
            selection.set(appGroup,enabled:true)
            check("group returns to All",selection.groupState(appGroup) == .on)
            selection.set(choices,enabled:true)
            check("bulk selection cannot enable protected formats",choices.filter{!$0.eligible}.allSatisfy{!selection.selected.contains($0.type.identifier)})
        }
        // Use a stable app group: the real Orkhon group starts collapsed when
        // the user has already applied defaults on this Mac.
        let setupChoices=choices.map { choice in
            choice.eligible ? AssociationChoice(type:choice.type,extensions:choice.extensions,previous:"com.apple.TextEdit",observed:"com.apple.TextEdit",currentName:"TextEdit",eligible:true,reason:nil):choice
        }
        let setup=FirstLaunchSetup(parent:window,environment:AssociationSetupEnvironment(choices:{setupChoices},apply:{_ in []},canApply:false,complete:{}),onFinish:{})
        func descendants(_ view:NSView)->[NSView] {view.subviews.flatMap{[$0]+descendants($0)}}
        if let content=setup.window?.contentView,let json=choices.first(where:{$0.extensions.contains("json") && $0.eligible}) {
            let views=descendants(content)
            if let item=views.compactMap({$0 as? NSButton}).first(where:{$0.identifier?.rawValue==json.type.identifier}),let scroll=views.compactMap({$0 as? NSScrollView}).first {
                scroll.contentView.scroll(to:NSPoint(x:0,y:80));let position=scroll.contentView.bounds.origin
                item.performClick(nil)
                let same=descendants(content).compactMap{$0 as? NSButton}.first{$0.identifier?.rawValue==json.type.identifier}
                check("selection retains existing item views",same === item && item.state == .off)
                check("selection does not move scroll position",scroll.contentView.bounds.origin==position)
                let group=descendants(content).compactMap{$0 as? NSButton}.first{$0.accessibilityLabel()?.contains("Use Orkhon for TextEdit formats:")==true}
                check("group switch visibly becomes Selective",group?.state == .mixed && group?.accessibilityLabel()?.hasSuffix("Selective")==true)
                group?.performClick(nil)
                check("Selective group switch selects all",item.state == .on && group?.state == .on)
                group?.performClick(nil)
                check("All group switch turns off",item.state == .off && group?.state == .off)
            } else {check("grouped setup controls exist",false)}
        }
        check("browser and media absent from association choices",!choices.contains{!Set($0.extensions).isDisjoint(with:["html","htm","mts","m2ts","ts","svg"]) && $0.eligible})
        return results
    }
}
