import AppKit
import CoreServices

/// Exercise the packaged declarations with a disposable app identity. Never
/// launch the editor, write default preferences, or register its real bundle ID.
@main
struct OpenWithTests {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static func main() {
        do {try run()}
        catch {fputs("FAIL: \(error)\n",stderr);exit(1)}
    }
    @MainActor static func run() throws {
        let fm=FileManager.default
        let app=URL(fileURLWithPath:CommandLine.arguments[1])
        let resources=app.appendingPathComponent("Contents/Resources")
        var checks=0
        func check(_ condition:Bool,_ message:String) throws {
            checks+=1
            if !condition {throw Failure(description:message)}
        }
        var info=try PropertyListSerialization.propertyList(from:Data(contentsOf:app.appendingPathComponent("Contents/Info.plist")),format:nil) as! [String:Any]
        let declarations=info["CFBundleDocumentTypes"] as? [[String:Any]] ?? []
        try check(!declarations.isEmpty,"Missing document declarations")
        for record in declarations {
            try check(record["CFBundleTypeRole"] as? String == "Editor","Document role must be Editor")
            try check(record["LSHandlerRank"] as? String == "Alternate","Open With must use Alternate rank")
            let icon=record["CFBundleTypeIconFile"] as? String ?? ""
            try check(!icon.isEmpty && fm.fileExists(atPath:resources.appendingPathComponent(icon).path),"Missing document icon")
        }
        let advertised=Set(declarations.flatMap{$0["CFBundleTypeExtensions"] as? [String] ?? []})
        let syntax=try JSONDecoder().decode([String].self,from:Data(contentsOf:resources.appendingPathComponent("supported-extensions.json")))
        for ext in Set(syntax).union(AssociationPolicy.sourceExtensions) {
            try check(advertised.contains(ext),"Open With omitted .\(ext)")
        }
        for ext in ["html","svg","ts","mts"] {
            try check(advertised.contains(ext) && !AssociationPolicy.sourceExtensions.contains(ext),"Open With must not expand defaults: .\(ext)")
        }
        for ext in ["pdf","docx","numbers","xlsx","mp4","zip"] {
            try check(!advertised.contains(ext),"Binary format advertised as editable: .\(ext)")
        }

        // --manifest-only works without a logged-in Launch Services session.
        if CommandLine.arguments.contains("--manifest-only") {
            print("\(checks) packaged Open With checks passed (\(advertised.count) extensions)")
            return
        }
        // Launch Services excludes apps under the system temporary directory.
        let scratch=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("work/orkhon-open-with-\(UUID().uuidString)")
        let probe=scratch.appendingPathComponent("Open With Test.app")
        let contents=probe.appendingPathComponent("Contents")
        let identifier="app.orkhon.open-with-test."+UUID().uuidString.lowercased()
        var registered=false
        defer {
            if registered {
                let unregister=Process()
                unregister.executableURL=URL(fileURLWithPath:"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
                unregister.arguments=["-u",probe.path]
                do {try unregister.run();unregister.waitUntilExit()}
                catch {fputs("Could not unregister test app: \(error)\n",stderr)}
            }
            try? fm.removeItem(at:scratch)
        }
        try fm.createDirectory(at:contents.appendingPathComponent("MacOS"),withIntermediateDirectories:true)
        try fm.createDirectory(at:contents.appendingPathComponent("Resources"),withIntermediateDirectories:true)
        let executable=info["CFBundleExecutable"] as! String
        try fm.copyItem(at:app.appendingPathComponent("Contents/MacOS/\(executable)"),to:contents.appendingPathComponent("MacOS/OpenWithTest"))
        try fm.copyItem(at:resources.appendingPathComponent("DocumentIcon.icns"),to:contents.appendingPathComponent("Resources/DocumentIcon.icns"))
        info["CFBundleIdentifier"]=identifier
        info["CFBundleName"]="Open With Test"
        info["CFBundleDisplayName"]="Open With Test"
        info["CFBundleExecutable"]="OpenWithTest"
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
        let signing=Process()
        signing.executableURL=URL(fileURLWithPath:"/usr/bin/codesign")
        signing.arguments=["--force","--sign","-",probe.path]
        try signing.run();signing.waitUntilExit()
        try check(signing.terminationStatus == 0,"Could not sign disposable app identity")
        let extensions=["txt","text","json","jsonc","json5","toml","yaml","yml","md","markdown","cpp","hpp","swift","py","rs","go","js","tsx","cts","css","xml","ini","cfg","sql","csv","tsv","log","html","htm","shtml","xhtml","svg","ts","mts","awk","lisp","tcl","nix","zig"]
        var fixtures:[String:URL]=[:]
        var previous:[String:URL]=[:]
        for ext in extensions {
            let file=scratch.appendingPathComponent("fixture.\(ext)")
            try Data("Open With test\n".utf8).write(to:file)
            fixtures[ext]=file
            previous[ext]=NSWorkspace.shared.urlForApplication(toOpen:file)
        }
        let status=LSRegisterURL(probe as CFURL,true)
        registered=true
        try check(status == noErr,"Test app registration failed: \(status)")
        for ext in extensions {
            let file=fixtures[ext]!
            // Registration and Finder's list can propagate asynchronously.
            var listed=false
            for _ in 0..<20 {
                listed=NSWorkspace.shared.urlsForApplications(toOpen:file).contains {
                    Bundle(url:$0)?.bundleIdentifier == identifier
                }
                if listed {break}
                Thread.sleep(forTimeInterval:0.05)
            }
            let candidates=NSWorkspace.shared.urlsForApplications(toOpen:file)
            try check(listed,"Finder's candidate list omitted .\(ext); candidates: \(candidates.map{$0.lastPathComponent}); registered path: \(NSWorkspace.shared.urlForApplication(withBundleIdentifier:identifier)?.path ?? "none")")
            if let before=previous[ext] {
                let after=NSWorkspace.shared.urlForApplication(toOpen:file)
                try check(after?.resolvingSymlinksInPath() == before.resolvingSymlinksInPath(),"Registration changed the existing default for .\(ext)")
            }
        }
        print("\(checks) Open With checks passed: \(advertised.count) declared extensions; \(extensions.count) real macOS candidate lookups; existing defaults unchanged")
    }
}
