import AppKit
import UniformTypeIdentifiers

extension EditorWindowController {
    /// Real controls with a simulated partial macOS failure. These checks never
    /// apply real file defaults or write first-launch preferences.
    func runAssociationSetupTests() async -> [String:Bool] {
        var results:[String:Bool]=[:]
        func check(_ name:String,_ value:Bool) {results["File Defaults: "+name]=value;print("\(value ? "PASS":"FAIL"): File Defaults: \(name)")}
        func descendants(_ view:NSView)->[NSView] {view.subviews.flatMap{[$0]+descendants($0)}}
        func choice(_ type:UTType,_ extensions:[String],_ app:String,_ name:String,previous:String?=nil)->AssociationChoice {
            let prior=previous ?? app
            let reason=AssociationPolicy.ineligibilityReason(extensions:extensions,isSource:type.conforms(to:.text))
            return AssociationChoice(type:type,extensions:extensions,previous:prior,observed:app,currentName:name,eligible:reason==nil,reason:reason)
        }
        let text=choice(.plainText,["txt","text"],"com.apple.TextEdit","TextEdit")
        let csv=choice(.commaSeparatedText,["csv"],"com.apple.iWork.Numbers","Numbers")
        let tsv=choice(.tabSeparatedText,["tsv"],"com.apple.iWork.Numbers","Numbers")
        let log=choice(UTType("com.apple.log")!,["log"],"com.apple.Console","Console")
        let html=choice(.html,["html"],"com.apple.Safari","Safari")
        let json=choice(.json,["json"],"example.unknown-app","Another App")
        let xml=choice(.xml,["xml"],"com.apple.Safari","Safari")
        var observed=[text,csv,tsv,log,html,json,xml],attempts:[[AssociationChoice]]=[]
        var completed=false,finished=false
        let environment=AssociationSetupEnvironment(choices:{observed},apply:{ selected in
            attempts.append(selected)
            if attempts.count==1 {
                observed[0]=choice(.plainText,["txt","text"],"app.orkhon.editor","Orkhon Code",previous:"com.apple.TextEdit")
                // Another app changes TSV during the first attempt.
                observed[2]=choice(.tabSeparatedText,["tsv"],"com.apple.Safari","Safari")
                return [".csv: simulated macOS failure"]
            }
            return []
        },canApply:true,complete:{completed=true})
        let setup=FirstLaunchSetup(parent:window,environment:environment,onFinish:{finished=true})
        guard let panel=setup.window,let content=panel.contentView else {check("setup exists",false);return results}
        func buttons()->[NSButton] {descendants(content).compactMap{$0 as? NSButton}}
        func format(_ type:UTType)->NSButton? {buttons().first{$0.identifier?.rawValue==type.identifier}}
        func applyButton()->NSButton? {buttons().first{$0.identifier?.rawValue=="applyFileDefaults"}}
        setup.present(on:window)
        defer {if panel.sheetParent != nil {window.endSheet(panel)};panel.orderOut(nil)}
        for item in [text,csv,tsv,log,json,xml] {
            check("\(item.currentName) \(item.label) selectable",format(item.type)?.isEnabled==true && format(item.type)?.state == .on)
        }
        check("nothing applied before confirmation",attempts.isEmpty && !completed)
        check("HTML stays excluded regardless of current app",format(html.type)?.isEnabled==false)
        format(log.type)?.performClick(nil)
        check("Console opt-out selectable",format(log.type)?.state == .off)
        applyButton()?.performClick(nil)
        check("controls temporarily disabled while applying",applyButton()?.isEnabled==false && format(text.type)?.isEnabled==false)
        for _ in 0..<100 {if panel.attachedSheet != nil {break};try? await Task.sleep(nanoseconds:20_000_000)}
        check("partial failure explained in an alert",panel.attachedSheet != nil && attempts.count==1)
        if let alert=panel.attachedSheet,let alertContent=alert.contentView {
            descendants(alertContent).compactMap{$0 as? NSButton}.first{$0.title=="OK"}?.performClick(nil)
        }
        for _ in 0..<100 {if panel.attachedSheet==nil {break};try? await Task.sleep(nanoseconds:20_000_000)}
        check("partial failure keeps setup open",!completed && !finished)
        check("TextEdit choices re-enabled after failure",format(text.type)?.isEnabled==true)
        check("Numbers choices re-enabled after failure",format(csv.type)?.isEnabled==true)
        check("Console opt-out preserved after failure",format(log.type)?.isEnabled==true && format(log.type)?.state == .off)
        check("search re-enabled after failure",descendants(content).compactMap{$0 as? NSTextField}.first{$0.accessibilityLabel()=="Search file defaults"}?.isEnabled==true)
        check("retry enabled after failure",applyButton()?.isEnabled==true)
        let numbersToggle=buttons().first{$0.accessibilityLabel()?.contains("Use Orkhon for Numbers formats:")==true}
        numbersToggle?.performClick(nil)
        check("group toggle still works after failure",numbersToggle?.isEnabled==true && format(csv.type)?.state == .off)
        numbersToggle?.performClick(nil)
        check("individual toggle still works after failure",format(csv.type)?.state == .on)
        applyButton()?.performClick(nil)
        for _ in 0..<100 {if finished {break};try? await Task.sleep(nanoseconds:20_000_000)}
        check("retry completes successfully",attempts.count==2 && completed && finished)
        if attempts.count==2 {
            let retried=attempts[1]
            check("retry uses refreshed defaults after partial success",retried.first{$0.type==text.type}?.observed=="app.orkhon.editor")
            check("retry preserves opt-outs",!retried.contains{$0.type==log.type})
            check("retry uses new current app without locking the format",retried.first{$0.type==tsv.type}?.observed=="com.apple.Safari")
            check("retry still excludes HTML",!retried.contains{$0.type==html.type})
            check("retry includes failed eligible formats",retried.contains{$0.type==csv.type})
        }
        var refresh=AssociationSelection([csv,log])
        refresh.toggle(log)
        let ambiguous=choice(.commaSeparatedText,["csv","xls"],"example.unknown-app","Another App")
        refresh.refresh([ambiguous,log])
        check("refresh rejects newly ambiguous aliases and retains opt-outs",refresh.chosen.isEmpty)
        return results
    }
}
