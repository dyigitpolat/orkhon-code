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
        let environment=AssociationSetupEnvironment(choices:{observed},apply:{ selected,_ in
            attempts.append(selected)
            if attempts.count==1 {
                observed[0]=choice(.plainText,["txt","text"],"app.orkhon.editor","Orkhon Code",previous:"com.apple.TextEdit")
                // Another app changes TSV during the first attempt.
                observed[2]=choice(.tabSeparatedText,["tsv"],"com.apple.Safari","Safari")
                return AssociationApplyResult(failures:[".csv: simulated macOS failure"],kept:Set([json.type.identifier,xml.type.identifier]))
            }
            return AssociationApplyResult()
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
        check("Multiple Keep decisions remain deselected after a later failure",format(json.type)?.state == .off && format(xml.type)?.state == .off)
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
            check("retry does not re-request declined types",!retried.contains{$0.type==json.type || $0.type==xml.type})
            check("retry uses new current app without locking the format",retried.first{$0.type==tsv.type}?.observed=="com.apple.Safari")
            check("retry still excludes HTML",!retried.contains{$0.type==html.type})
            check("retry includes failed eligible formats",retried.contains{$0.type==csv.type})
        }
        var refresh=AssociationSelection([csv,log])
        refresh.toggle(log)
        let ambiguous=choice(.commaSeparatedText,["csv","xls"],"example.unknown-app","Another App")
        refresh.refresh([ambiguous,log])
        check("refresh rejects newly ambiguous aliases and retains opt-outs",refresh.chosen.isEmpty)
        results.merge(await runAssociationQueueTests()){_,new in new}
        results.merge(await runAssociationConsentTests()){_,new in new}
        return results
    }
}

extension EditorWindowController {
    func runAssociationQueueTests() async -> [String:Bool] {
        var results:[String:Bool]=[:]
        func check(_ name:String,_ value:Bool) {results["File Defaults queue: "+name]=value}
        let target="app.orkhon.editor"
        func choice(_ index:Int,_ app:String="example.editor")->AssociationChoice {
            AssociationChoice(type:UTType(mimeType:"text/x-orkhon-queue-test-\(index)",conformingTo:.text)!,extensions:["json"],previous:app,observed:app,currentName:"Previous Editor",eligible:true,reason:nil)
        }
        let choices=(0..<150).map{choice($0)}
        var defaults=Dictionary(uniqueKeysWithValues:choices.map{($0.type.identifier,$0.observed!)})
        var requests:[String]=[],backups=0,mode="success"
        var session=AssociationApplySession()
        let environment=AssociationApplyEnvironment(current:{defaults[$0.identifier]},backup:{_ in
            backups+=1
            if mode=="backup-failure" {throw CocoaError(.fileWriteNoPermission)}
        },request:{type in
            requests.append(type.identifier)
            check("backup precedes every request",backups>0)
            if mode=="keep" || (["mixed-keep","keep-then-stop","keep-then-fail"].contains(mode) && requests.count==1) {
                if mode=="keep-then-stop" {session.stopRequested=true}
                return NSError(domain:NSCocoaErrorDomain,code:NSUserCancelledError)
            }
            if mode=="mixed-keep" && requests.count==75 {return NSError(domain:NSOSStatusErrorDomain,code:-128)}
            if mode=="mixed-keep" && requests.count==150 {
                return NSError(domain:NSCocoaErrorDomain,code:NSFileWriteUnknownError,userInfo:[NSUnderlyingErrorKey:NSError(domain:NSOSStatusErrorDomain,code:-128)])
            }
            if mode=="keep-then-fail" {return NSError(domain:NSOSStatusErrorDomain,code:-50)}
            if mode=="failure" {return NSError(domain:NSOSStatusErrorDomain,code:-50)}
            defaults[type.identifier]=target
            if mode=="cancel" {session.stopRequested=true}
            if mode=="changed" {defaults[choices[1].type.identifier]="another.unreviewed.app"}
            return nil
        })
        func reset(_ next:String) {
            mode=next;requests=[];backups=0;session=AssociationApplySession()
            defaults=Dictionary(uniqueKeysWithValues:choices.map{($0.type.identifier,$0.observed!)})
        }
        let success=await AssociationApplier.run(choices+[choices[0]],target:target,session:session,environment:environment)
        check("150 types applied once, duplicate aliases skipped",success.failures.isEmpty && requests.count==150)
        check("baseline saved once for the batch",backups==1)
        reset("keep")
        let kept=await AssociationApplier.run(choices,target:target,session:session,environment:environment)
        check("Keep continues through all 150 requests",!kept.stopped && kept.failures.isEmpty && kept.kept.count==150 && requests.count==150)
        check("Keep leaves every declined app unchanged",choices.allSatisfy{defaults[$0.type.identifier]==$0.observed})
        reset("mixed-keep")
        let mixed=await AssociationApplier.run(choices,target:target,session:session,environment:environment)
        let declined=Set([choices[0],choices[74],choices[149]].map{$0.type.identifier})
        check("Mixed Keep and Use decisions reach the last type",!mixed.stopped && mixed.failures.isEmpty && mixed.kept==declined && requests.count==150)
        check("Only approved types change their defaults",choices.allSatisfy{defaults[$0.type.identifier] == (declined.contains($0.type.identifier) ? $0.observed:target)})
        reset("keep-then-stop")
        let keepThenStop=await AssociationApplier.run(choices,target:target,session:session,environment:environment)
        check("Explicit Stop still works after Keep",keepThenStop.stopped && keepThenStop.kept==Set([choices[0].type.identifier]) && requests.count==1)
        reset("keep-then-fail")
        let keepThenFail=await AssociationApplier.run(choices,target:target,session:session,environment:environment)
        check("A later failure retains previous Keep decisions",keepThenFail.failures.count==1 && keepThenFail.kept==Set([choices[0].type.identifier]) && requests.count==2)
        reset("cancel")
        let stopped=await AssociationApplier.run(choices,target:target,session:session,environment:environment)
        check("Stop finishes current request without issuing next",stopped.stopped && requests.count==1 && defaults[choices[0].type.identifier]==target)
        check("Stop leaves all remaining apps unchanged",choices.dropFirst().allSatisfy{defaults[$0.type.identifier]==$0.observed})
        reset("failure")
        let failed=await AssociationApplier.run(choices,target:target,session:session,environment:environment)
        check("First OS failure stops a long prompt chain",failed.failures.count==1 && requests.count==1)
        reset("changed")
        let changed=await AssociationApplier.run(choices,target:target,session:session,environment:environment)
        check("Never replaces an unreviewed app changed during consent",changed.failures.count==1 && requests.count==1)
        reset("backup-failure")
        let unbacked=await AssociationApplier.run(choices,target:target,session:session,environment:environment)
        check("Backup failure makes no system requests",unbacked.failures.count==1 && requests.isEmpty)
        reset("success");session.stopRequested=true
        let cancelled=await AssociationApplier.run(choices,target:target,session:session,environment:environment)
        check("Cancellation before start is side-effect free",cancelled.stopped && requests.isEmpty && backups==0)
        session=AssociationApplySession()
        let already=await AssociationApplier.run([choice(0,target)],target:target,session:session,environment:environment)
        check("Already assigned formats do not prompt",already.failures.isEmpty && requests.isEmpty && backups==0)
        do {
            try FileAssociations.saveBackups([choices[0]])
            try FileAssociations.saveBackups([choice(0,"newer.app")])
            let saved=try JSONDecoder().decode([AssociationBackup].self,from:Data(contentsOf:FileAssociations.backupURL))
            check("Retry preserves original restoration record",saved.first{$0.uti==choices[0].type.identifier}?.previous==choices[0].previous)
        } catch {check("Retry preserves original restoration record",false)}
        return results
    }

    func runAssociationConsentTests() async -> [String:Bool] {
        var results:[String:Bool]=[:]
        func check(_ name:String,_ value:Bool) {results["File Defaults consent: "+name]=value}
        func descendants(_ view:NSView)->[NSView] {view.subviews.flatMap{[$0]+descendants($0)}}
        var requests=0,completed=false
        let choices=[AssociationChoice(type:.plainText,extensions:["txt","text"],previous:"com.apple.TextEdit",observed:"com.apple.TextEdit",currentName:"TextEdit",eligible:true,reason:nil)]
        let environment=AssociationSetupEnvironment(choices:{choices},apply:{_,session in
            requests+=1;session.progress(1,1,choices[0])
            for _ in 0..<100 {if session.stopRequested {break};try? await Task.sleep(nanoseconds:10_000_000)}
            return AssociationApplyResult(stopped:session.stopRequested)
        },canApply:true,complete:{completed=true},requiresIndividualConsent:true)
        let setup=FirstLaunchSetup(parent:window,environment:environment,onFinish:{})
        guard let panel=setup.window,let content=panel.contentView else {return ["consent UI exists":false]}
        setup.present(on:window)
        defer {if panel.sheetParent != nil {window.endSheet(panel)};panel.orderOut(nil)}
        func button(_ id:String)->NSButton? {descendants(content).compactMap{$0 as? NSButton}.first{$0.identifier?.rawValue==id}}
        func alertButton(_ title:String)->NSButton? {panel.attachedSheet?.contentView.flatMap{descendants($0).compactMap{$0 as? NSButton}.first{$0.title==title}}}
        let apply=button("applyFileDefaults"),stop=button("stopFileDefaults")
        check("Count is by shared type, not extension",apply?.title=="Review 1 macOS confirmation")
        apply?.performClick(nil)
        check("Bulk consent warning appears before any OS request",panel.attachedSheet != nil && requests==0)
        alertButton("Review selection")?.performClick(nil)
        for _ in 0..<100 {if panel.attachedSheet==nil {break};try? await Task.sleep(nanoseconds:10_000_000)}
        check("Review selection makes no changes",requests==0 && !completed)
        apply?.performClick(nil);alertButton("Start confirmations")?.performClick(nil)
        for _ in 0..<100 {if requests==1 {break};try? await Task.sleep(nanoseconds:10_000_000)}
        check("Stop stays accessible while macOS request is pending",requests==1 && stop?.isEnabled==true)
        stop?.performClick(nil)
        for _ in 0..<100 {if apply?.isEnabled==true {break};try? await Task.sleep(nanoseconds:10_000_000)}
        check("Stopping restores editable selection without finishing setup",apply?.isEnabled==true && !completed)
        check("Remaining formats stay available to resume",descendants(content).compactMap{$0 as? NSButton}.first{$0.identifier?.rawValue==UTType.plainText.identifier}?.state == .on)
        stop?.performClick(nil)
        check("Continue to editor works after stopping",completed)
        return results
    }
}
