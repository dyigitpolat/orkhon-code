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
    static var canApply:Bool {
        let path=Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let temporary=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return Bundle.main.bundleIdentifier == "app.orkhon.editor" && !path.hasPrefix(temporary+"/") && !path.hasPrefix("/private/tmp/")
    }
    static func choices() -> [AssociationChoice] {
        var results:[AssociationChoice]=[]
        var appNames:[String:String]=[:]
        let baselineURL=backupURL.deletingLastPathComponent().appendingPathComponent("Installation Defaults.json")
        let baseline=(try? Data(contentsOf:baselineURL)).flatMap{try? JSONDecoder().decode([String:String].self,from:$0)} ?? [:]
        let records=(try? Data(contentsOf:backupURL)).flatMap{try? JSONDecoder().decode([AssociationBackup].self,from:$0)} ?? []
        // Resolve every reviewed extension on this Mac, rather than only a small
        // list of Apple source-code identifiers. Aliases share a single checkbox.
        var groups:[UTType:Set<String>]=[:]
        for ext in AssociationPolicy.sourceExtensions {
            guard let type=UTType(filenameExtension:ext) else {continue}
            groups[type,default:[]].insert(ext)
        }
        for (type,knownExtensions) in groups {
            let identifier=type.identifier
            let aliases=Set((type.tags[.filenameExtension] ?? [])+Array(knownExtensions)).map{$0.lowercased()}.sorted()
            let observed=LSCopyDefaultRoleHandlerForContentType(identifier as CFString,.all)?.takeRetainedValue() as String?
            let saved=records.first{$0.uti==identifier}?.previous ?? baseline[identifier]
            let current=observed?.hasPrefix("app.orkhon.") == true ? saved.flatMap{$0.isEmpty ? nil:$0}:observed
            let safeAliases=Set(aliases).isSubset(of:AssociationPolicy.sourceExtensions)
            let specialist=current.map{!AssociationPolicy.editors.contains($0.lowercased())} ?? false
            let isText=type.isDynamic || type.conforms(to:.text)
            let eligible=safeAliases && isText && !specialist
            let name:String
            if let observed {
                if let cached=appNames[observed] {name=cached}
                else {let appURL=NSWorkspace.shared.urlForApplication(withBundleIdentifier:observed);name=appURL.map{FileManager.default.displayName(atPath:$0.path).replacingOccurrences(of:".app",with:"")} ?? observed;appNames[observed]=name}
            } else {name="No default app"}
            let reason = !isText ? "macOS identifies this format as a non-text document":(!safeAliases ? "macOS also maps this type to an ambiguous extension":(specialist ? "Kept in its current specialist app":nil))
            results.append(AssociationChoice(type:type,extensions:aliases,previous:current,observed:observed,currentName:name,eligible:eligible,reason:reason))
        }
        return results.sorted{$0.label.localizedStandardCompare($1.label) == .orderedAscending}
    }
    static var backupURL:URL {
        if let path=ProcessInfo.processInfo.environment["ORKHON_TEST_DATA"] {return URL(fileURLWithPath:path).appendingPathComponent("File Associations.json")}
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Orkhon Editor/File Associations.json")
    }
    static func apply(_ choices:[AssociationChoice]) async -> [String] {
        guard canApply else {
            return ["File defaults can be applied from the installed app."]
        }
        var failures:[String]=[]
        for choice in choices where choice.eligible {
            // Re-check after the consent screen, in case another app changed this default.
            let current=LSCopyDefaultRoleHandlerForContentType(choice.type.identifier as CFString,.all)?.takeRetainedValue() as String?
            guard current == choice.observed,AssociationPolicy.eligible(extensions:(choice.type.tags[.filenameExtension] ?? [])+choice.extensions,isSource:choice.type.isDynamic || choice.type.conforms(to:.text),current:choice.previous) else { failures.append("\(choice.label): its current app changed. Review it again.");continue }
            do {
                var records:[AssociationBackup]=[]
                if FileManager.default.fileExists(atPath:backupURL.path) { records=try JSONDecoder().decode([AssociationBackup].self,from:Data(contentsOf:backupURL)) }
                if !records.contains(where:{$0.uti == choice.type.identifier}) {
                    records.append(AssociationBackup(uti:choice.type.identifier,previous:choice.previous,date:Date()))
                    try FileManager.default.createDirectory(at:backupURL.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try JSONEncoder().encode(records).write(to:backupURL,options:.atomic)
                }
            } catch { failures.append("\(choice.label): could not save its previous app. No change made.");continue }
            if current == Bundle.main.bundleIdentifier {continue}
            let error:Error? = await withCheckedContinuation { continuation in
                NSWorkspace.shared.setDefaultApplication(at:Bundle.main.bundleURL,toOpen:choice.type) { continuation.resume(returning:$0) }
            }
            var now=LSCopyDefaultRoleHandlerForContentType(choice.type.identifier as CFString,.all)?.takeRetainedValue() as String?
            // LaunchServices may finish updating shortly after the completion call.
            // Retry reads only; never silently change a failed choice another way.
            if error == nil {
                for _ in 0..<4 where now?.lowercased() != Bundle.main.bundleIdentifier?.lowercased() {
                    try? await Task.sleep(nanoseconds:75_000_000)
                    now=LSCopyDefaultRoleHandlerForContentType(choice.type.identifier as CFString,.all)?.takeRetainedValue() as String?
                }
            }
            if let error,now?.lowercased() != Bundle.main.bundleIdentifier?.lowercased() {
                let native=error as NSError
                failures.append("\(choice.label): \(native.localizedDescription) (\(native.domain) \(native.code)). Current default: \(now ?? "none").")
            } else if now?.lowercased() != Bundle.main.bundleIdentifier?.lowercased() {
                failures.append("\(choice.label): macOS still reports \(now ?? "no default app"). Reopen the installed Orkhon Code from Applications and review this group again.")
            }
        }
        return failures
    }
}


extension EditorWindowController {
    func offerFirstLaunchSetup() {
        guard ProcessInfo.processInfo.environment["ORKHON_SKIP_SETUP"] == nil else{return}
        let firstLaunch = !UserDefaults.standard.bool(forKey:"fileSetupCompletedV6")
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
