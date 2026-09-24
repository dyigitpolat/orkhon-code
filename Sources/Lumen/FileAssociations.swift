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

/// One reviewed operation. Cancelling never cancels an in-flight macOS consent
/// dialog; it prevents the next request after that dialog has been answered.
@MainActor
final class AssociationApplySession {
    var stopRequested=false
    var progress:(Int,Int,AssociationChoice)->Void={_,_,_ in}
}
struct AssociationApplyResult {
    var failures:[String]=[]
    var stopped=false
    var kept:String?
}

@MainActor
struct AssociationApplyEnvironment {
    var current:(UTType)->String?
    var backup:([AssociationChoice]) throws -> Void
    var request:(UTType) async -> Error?
}

@MainActor
enum AssociationApplier {
    static func run(_ choices:[AssociationChoice],target:String,session:AssociationApplySession,environment:AssociationApplyEnvironment) async -> AssociationApplyResult {
        var seen=Set<String>()
        let pending=choices.filter{$0.eligible && $0.observed?.lowercased() != target.lowercased() && seen.insert($0.type.identifier).inserted}
        guard !pending.isEmpty else{return AssociationApplyResult()}
        if session.stopRequested {return AssociationApplyResult(stopped:true)}
        // Save the whole reviewed baseline atomically before the first mutation.
        do {try environment.backup(pending)}
        catch {return AssociationApplyResult(failures:["Could not save the previous apps. No defaults were changed."])}
        for (index,choice) in pending.enumerated() {
            if session.stopRequested {return AssociationApplyResult(stopped:true)}
            let current=environment.current(choice.type)
            // Another app may have changed the default while an earlier prompt
            // was open. Never replace an app the user has not reviewed.
            guard current?.lowercased() == choice.observed?.lowercased(),
                  AssociationPolicy.eligible(extensions:(choice.type.tags[.filenameExtension] ?? [])+choice.extensions,isSource:choice.type.isDynamic || choice.type.conforms(to:.text)) else {
                return AssociationApplyResult(failures:["\(choice.label): its current app or supported extensions changed. Review it again."])
            }
            session.progress(index+1,pending.count,choice)
            await Task.yield()
            if session.stopRequested {return AssociationApplyResult(stopped:true)}
            let error=await environment.request(choice.type)
            var now=environment.current(choice.type)
            if error == nil {
                for _ in 0..<4 where now?.lowercased() != target.lowercased() {
                    try? await Task.sleep(nanoseconds:75_000_000)
                    now=environment.current(choice.type)
                }
            }
            if now?.lowercased() != target.lowercased() {
                if let native=error as NSError?,
                   (native.domain == NSCocoaErrorDomain && native.code == NSUserCancelledError || native.domain == NSOSStatusErrorDomain && native.code == -128) {
                    return AssociationApplyResult(stopped:true,kept:choice.type.identifier)
                }
                let message=error?.localizedDescription ?? "macOS kept the current default"
                // A rejection or failure stops the queue; no hundred-dialog tail.
                return AssociationApplyResult(failures:["\(choice.label): \(message). Current app: \(now ?? "none")."],stopped:true)
            }
        }
        return AssociationApplyResult()
    }
}

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
            let isText=type.isDynamic || type.conforms(to:.text)
            let reason=AssociationPolicy.ineligibilityReason(extensions:aliases,isSource:isText)
            let name:String
            if let observed {
                if let cached=appNames[observed] {name=cached}
                else {let appURL=NSWorkspace.shared.urlForApplication(withBundleIdentifier:observed);name=appURL.map{FileManager.default.displayName(atPath:$0.path).replacingOccurrences(of:".app",with:"")} ?? observed;appNames[observed]=name}
            } else {name="No default app"}
            results.append(AssociationChoice(type:type,extensions:aliases,previous:current,observed:observed,currentName:name,eligible:reason == nil,reason:reason))
        }
        return results.sorted{$0.label.localizedStandardCompare($1.label) == .orderedAscending}
    }
    static var backupURL:URL {
        if let path=ProcessInfo.processInfo.environment["ORKHON_TEST_DATA"] {return URL(fileURLWithPath:path).appendingPathComponent("File Associations.json")}
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Orkhon Editor/File Associations.json")
    }
    static var requiresIndividualConsent:Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion:26,minorVersion:4,patchVersion:0))
    }
    static func saveBackups(_ choices:[AssociationChoice]) throws {
        var records:[AssociationBackup]=[]
        if FileManager.default.fileExists(atPath:backupURL.path) {records=try JSONDecoder().decode([AssociationBackup].self,from:Data(contentsOf:backupURL))}
        for choice in choices where !records.contains(where:{$0.uti==choice.type.identifier}) {
            records.append(AssociationBackup(uti:choice.type.identifier,previous:choice.previous,date:Date()))
        }
        try FileManager.default.createDirectory(at:backupURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(records).write(to:backupURL,options:.atomic)
    }
    static func apply(_ choices:[AssociationChoice],session:AssociationApplySession) async -> AssociationApplyResult {
        guard canApply,let identifier=Bundle.main.bundleIdentifier else {
            return AssociationApplyResult(failures:["File defaults can be applied from the installed app."])
        }
        let environment=AssociationApplyEnvironment(current:{type in
            LSCopyDefaultRoleHandlerForContentType(type.identifier as CFString,.all)?.takeRetainedValue() as String?
        },backup:saveBackups,request:{type in
            await withCheckedContinuation {continuation in
                NSWorkspace.shared.setDefaultApplication(at:Bundle.main.bundleURL,toOpen:type) {continuation.resume(returning:$0)}
            }
        })
        return await AssociationApplier.run(choices,target:identifier,session:session,environment:environment)
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
