import AppKit
import UniformTypeIdentifiers
import CoreServices

/// Syntax support is deliberately independent of Finder default-app eligibility.
/// Never infer that a file is safe to claim merely because a lexer recognizes it.

struct AssociationChoice {
    let type:UTType
    let extensions:[String]
    let previous:String?
    let observed:String?
    let currentName:String
    let eligible:Bool
    let reason:String?
    var label:String { extensions.map{"."+$0}.joined(separator:"  ") }
}
struct AssociationBackup:Codable { let uti:String;let previous:String?;let date:Date }

@MainActor
enum FileAssociations {
    static func choices() -> [AssociationChoice] {
        var results:[AssociationChoice]=[]
        let baselineURL=backupURL.deletingLastPathComponent().appendingPathComponent("Installation Defaults.json")
        let baseline=(try? Data(contentsOf:baselineURL)).flatMap{try? JSONDecoder().decode([String:String].self,from:$0)} ?? [:]
        let records=(try? Data(contentsOf:backupURL)).flatMap{try? JSONDecoder().decode([AssociationBackup].self,from:$0)} ?? []
        for (identifier,knownExtensions) in AssociationPolicy.catalog {
            let resolved=UTType(identifier)
            let type=resolved ?? UTType(importedAs:identifier,conformingTo:.sourceCode)
            let aliases=Set((resolved?.tags[.filenameExtension] ?? [])+knownExtensions).map{$0.lowercased()}.sorted()
            let observed=LSCopyDefaultRoleHandlerForContentType(identifier as CFString,.all)?.takeRetainedValue() as String?
            let saved=records.first{$0.uti==identifier}?.previous ?? baseline[identifier]
            let current=observed?.hasPrefix("app.orkhon.") == true ? saved.flatMap{$0.isEmpty ? nil:$0}:observed
            let safeAliases=Set(aliases).isSubset(of:AssociationPolicy.sourceExtensions)
            let specialist=current.map{!AssociationPolicy.editors.contains($0.lowercased())} ?? false
            let eligible=safeAliases && !specialist
            let appURL=current.flatMap{NSWorkspace.shared.urlForApplication(withBundleIdentifier:$0)}
            let name=appURL.map{FileManager.default.displayName(atPath:$0.path).replacingOccurrences(of:".app",with:"")} ?? current ?? "No default app"
            let reason = !safeAliases ? "macOS also maps this type to an ambiguous extension":(specialist ? "Kept in its current specialist app":nil)
            results.append(AssociationChoice(type:type,extensions:aliases,previous:current,observed:observed,currentName:name,eligible:eligible,reason:reason))
        }
        return results.sorted{$0.label.localizedStandardCompare($1.label) == .orderedAscending}
    }
    static var backupURL:URL {
        if let path=ProcessInfo.processInfo.environment["ORKHON_TEST_DATA"] {return URL(fileURLWithPath:path).appendingPathComponent("File Associations.json")}
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Orkhon Editor/File Associations.json")
    }
    static func apply(_ choices:[AssociationChoice]) async -> [String] {
        guard Bundle.main.bundleIdentifier == "app.orkhon.editor" else {
            return ["File defaults can be applied from the installed app."]
        }
        var failures:[String]=[]
        for choice in choices where choice.eligible {
            // Re-check after the consent screen, in case another app changed this default.
            let current=LSCopyDefaultRoleHandlerForContentType(choice.type.identifier as CFString,.all)?.takeRetainedValue() as String?
            guard current == choice.observed,AssociationPolicy.eligible(extensions:(choice.type.tags[.filenameExtension] ?? [])+choice.extensions,isSource:true,current:choice.previous) else { failures.append("\(choice.label): its current app changed. Review it again.");continue }
            do {
                var records:[AssociationBackup]=[]
                if FileManager.default.fileExists(atPath:backupURL.path) { records=try JSONDecoder().decode([AssociationBackup].self,from:Data(contentsOf:backupURL)) }
                if !records.contains(where:{$0.uti == choice.type.identifier}) {
                    records.append(AssociationBackup(uti:choice.type.identifier,previous:choice.previous,date:Date()))
                    try FileManager.default.createDirectory(at:backupURL.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try JSONEncoder().encode(records).write(to:backupURL,options:.atomic)
                }
            } catch { failures.append("\(choice.label): could not save its previous app. No change made.");continue }
            let error:Error? = await withCheckedContinuation { continuation in
                NSWorkspace.shared.setDefaultApplication(at:Bundle.main.bundleURL,toOpen:choice.type) { continuation.resume(returning:$0) }
            }
            let now=LSCopyDefaultRoleHandlerForContentType(choice.type.identifier as CFString,.all)?.takeRetainedValue() as String?
            if let error { failures.append("\(choice.label): \(error.localizedDescription)") }
            else if now != Bundle.main.bundleIdentifier { failures.append("\(choice.label): macOS did not confirm the change.") }
        }
        return failures
    }
}

@MainActor
final class FirstLaunchSetup:NSWindowController {
    private let choices:[AssociationChoice]
    private var toggles:[NSButton]=[]
    private let actionButton=PillButton(title:"Apply defaults and start editing",target:nil,action:nil)
    private let skipButton=NSButton(title:"Keep all current defaults",target:nil,action:nil)
    private let statusLabel=NSTextField(labelWithString:"")
    private let onFinish:()->Void
    private var busy=false
    init(parent:NSWindow,onFinish:@escaping ()->Void) {
        choices=FileAssociations.choices();self.onFinish=onFinish
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:660,height:570),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:panel);panel.title="Set up Orkhon Code";panel.titleVisibility = .hidden;panel.titlebarAppearsTransparent=true;panel.isReleasedWhenClosed=false;panel.appearance=parent.effectiveAppearance
        let content=NSView();panel.contentView=content
        let title=NSTextField(labelWithString:"Make Orkhon your source editor")
        title.font = .systemFont(ofSize:23,weight:.semibold);title.frame=NSRect(x:28,y:507,width:610,height:34)
        let detail=NSTextField(wrappingLabelWithString:"Recommended file types are selected. Deselect any you want to keep in their current app. Nothing changes until you confirm. C++ includes .cp because macOS shares its default.")
        detail.font = .systemFont(ofSize:13);detail.textColor = .secondaryLabelColor;detail.frame=NSRect(x:30,y:447,width:600,height:52)
        let scroll=NSScrollView(frame:NSRect(x:24,y:108,width:612,height:332));scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false
        let rows=NSView(frame:NSRect(x:0,y:0,width:598,height:max(332,CGFloat((choices.count+1)/2)*36)))
        for (index,choice) in choices.enumerated() {
            let x=CGFloat(index%2)*299,y=rows.bounds.height-CGFloat(index/2+1)*36
            let toggle=NSButton(checkboxWithTitle:choice.label,target:self,action:#selector(selectionChanged));toggle.frame=NSRect(x:x+5,y:y+13,width:282,height:22);toggle.font = .monospacedSystemFont(ofSize:12,weight:.medium);toggle.lineBreakMode = .byTruncatingTail;toggle.state = choice.eligible ? .on:.off;toggle.isEnabled=choice.eligible;toggle.toolTip=choice.reason ?? "\(choice.label) — currently \(choice.currentName)";toggle.setAccessibilityLabel("Open \(choice.label) in Orkhon; currently \(choice.currentName)")
            let label=NSTextField(labelWithString:choice.currentName+(choice.eligible ? "":" · protected"));label.frame=NSRect(x:x+25,y:y,width:255,height:17);label.font = .systemFont(ofSize:10);label.textColor = .secondaryLabelColor;label.lineBreakMode = .byTruncatingTail
            rows.addSubview(toggle);rows.addSubview(label);toggles.append(toggle)
        }
        if choices.isEmpty {let empty=NSTextField(wrappingLabelWithString:"File types could not be loaded. Reopen File Defaults to try again; no defaults have changed.");empty.frame=NSRect(x:18,y:140,width:560,height:50);rows.addSubview(empty)}
        scroll.documentView=rows;rows.scroll(NSPoint(x:0,y:rows.bounds.height))
        statusLabel.font = .systemFont(ofSize:11);statusLabel.textColor = .secondaryLabelColor;statusLabel.frame=NSRect(x:30,y:80,width:600,height:18);statusLabel.lineBreakMode = .byTruncatingTail
        skipButton.isBordered=false;skipButton.font = .systemFont(ofSize:12);skipButton.target=self;skipButton.action=#selector(skip);skipButton.frame=NSRect(x:24,y:25,width:200,height:36)
        actionButton.target=self;actionButton.action=#selector(applySelection);actionButton.font = .systemFont(ofSize:12,weight:.medium);actionButton.frame=NSRect(x:343,y:25,width:291,height:36)
        for view in [title,detail,scroll,statusLabel,skipButton,actionButton] {content.addSubview(view)}
        selectionChanged()
    }
    required init?(coder:NSCoder) {fatalError("Use init(parent:onFinish:)")}
    func present(on parent:NSWindow) {guard let window else{return};parent.beginSheet(window);window.makeFirstResponder(actionButton)}
    @objc private func selectionChanged() {
        let count=toggles.filter{$0.state == .on}.count
        actionButton.title=count==0 ? "Continue without changes":"Apply defaults and start editing"
        statusLabel.stringValue="\(count) file groups selected · Browser, media, design, and other ambiguous formats stay protected."
    }
    @objc private func skip() {guard !busy else{return};finish()}
    @objc private func applySelection() {
        guard !busy else{return}
        let selected=zip(choices,toggles).filter{$0.0.eligible && $0.1.state == .on}.map{$0.0}
        if selected.isEmpty {finish();return}
        busy=true;actionButton.isEnabled=false;skipButton.isEnabled=false;toggles.forEach{$0.isEnabled=false};statusLabel.stringValue="Applying your choices…"
        Task { [weak self] in
            let failures=await FileAssociations.apply(selected)
            guard let self else{return};self.busy=false
            if failures.isEmpty {self.finish()}
            else {self.skipButton.isEnabled=true;self.skipButton.title="Continue to editor";self.statusLabel.stringValue="Some choices were not changed."
                let alert=NSAlert();alert.messageText="macOS could not apply every choice";alert.informativeText=failures.joined(separator:"\n");alert.addButton(withTitle:"OK");if let window=self.window {alert.beginSheetModal(for:window,completionHandler:nil)}
            }
        }
    }
    private func finish() {UserDefaults.standard.set(true,forKey:"fileSetupCompletedV5");if let window {window.sheetParent?.endSheet(window);window.orderOut(nil)};onFinish()}
}

extension EditorWindowController {
    func offerFirstLaunchSetup() {
        guard ProcessInfo.processInfo.environment["ORKHON_SKIP_SETUP"] == nil else{return}
        let firstLaunch = !UserDefaults.standard.bool(forKey:"fileSetupCompletedV5")
        if firstLaunch || ProcessInfo.processInfo.arguments.contains("--welcome") {showWelcome()}
        if firstLaunch {showFileSetup(nil)}
        recordStartupTestIfRequested()
    }
    @objc func showFileSetup(_ sender:Any?) {
        guard window.attachedSheet == nil else{return}
        let setup=FirstLaunchSetup(parent:window) { [weak self] in self?.setupWindow=nil;self?.bringToFront() }
        setupWindow=setup;setup.present(on:window)
    }
}
