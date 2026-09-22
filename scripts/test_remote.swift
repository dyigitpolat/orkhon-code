import Foundation
@main struct RemoteTests {
 static func main() throws {
    var count=0
    func check(_ label:String,_ condition:Bool) {count+=1;if !condition {fputs("FAIL: \(label)\n",stderr);exit(1)}}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("orkhon-remote-fixture-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
    let workspace=try RemoteWorkspace(host:"local-test",directory:root.path,localTest:true)
    let unusual=root.appendingPathComponent("a 'quote'; $(touch NEVER)\nü.toml")
    let original=Data("title = \"é\"\n".utf8),updated=Data("title = \"updated\"\n".utf8)
    try original.write(to:unusual);try FileManager.default.setAttributes([.posixPermissions:0o640],ofItemAtPath:unusual.path)
    try FileManager.default.createDirectory(at:root.appendingPathComponent("folder"),withIntermediateDirectories:true)
    try Data("hidden".utf8).write(to:root.appendingPathComponent(".hidden"))
    try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:unusual)
    let entries=try workspace.list(root.path)
    check("NUL framing preserves quotes, whitespace and Unicode",entries.contains{$0.path==unusual.path})
    check("Hidden files included",entries.contains{$0.name==".hidden"})
    check("Directories sorted first",entries.first?.directory==true)
    check("Symlinks identified without traversal",entries.first{$0.name=="link"}?.symbolicLink==true)
    check("Byte-exact remote read",try workspace.read(unusual.path)==original)
    let hashes=try workspace.checksums([unusual.path,root.appendingPathComponent("link").path,root.appendingPathComponent("absent").path])
    check("Batch checksum preserves unusual paths",hashes[unusual.path]==RemoteWorkspace.checksum(original))
    check("Checksum rejects links and missing files",hashes[root.appendingPathComponent("link").path]=="missing" && hashes[root.appendingPathComponent("absent").path]=="missing")
    let modified=(try FileManager.default.attributesOfItem(atPath:unusual.path))[.modificationDate]!
    let sameSize=Data("title = \"ø\"\n".utf8)
    try sameSize.write(to:unusual);try FileManager.default.setAttributes([.modificationDate:modified],ofItemAtPath:unusual.path)
    check("Checksum detects same-size edit with unchanged mtime",try workspace.checksums([unusual.path])[unusual.path] != hashes[unusual.path])
    try original.write(to:unusual)
    try workspace.write(unusual.path,data:updated,expected:original)
    check("Byte-exact atomic save",try Data(contentsOf:unusual)==updated)
    check("Permissions retained",(try FileManager.default.attributesOfItem(atPath:unusual.path)[.posixPermissions] as? NSNumber)?.intValue==0o640)
    do {try workspace.write(unusual.path,data:original,expected:original);check("Reject stale snapshot",false)} catch {check("Reject stale snapshot",error.localizedDescription.contains("Conflict") && (error as? RemoteFailure)?.exitStatus==73)}
    check("Conflicting save keeps server data",try Data(contentsOf:unusual)==updated)
    do {_ = try workspace.read(root.appendingPathComponent("link").path);check("Reject symlink editing",false)} catch {check("Reject symlink editing",true)}
    try workspace.create(root.appendingPathComponent("new.txt").path,directory:false)
    try workspace.create(root.appendingPathComponent("new folder").path,directory:true)
    check("Create file and folder",FileManager.default.fileExists(atPath:root.appendingPathComponent("new.txt").path) && FileManager.default.fileExists(atPath:root.appendingPathComponent("new folder").path))
    do {try workspace.create(unusual.path,directory:false);check("Create cannot clobber",false)} catch {check("Create cannot clobber",true)}
    check("Control socket path fits Unix limit",workspace.controlPath.utf8.count<104)
    for host in ["-oProxyCommand=bad","user@host;rm", "host name","$(touch file)",""] {check("Host input validation",!RemoteWorkspace.validHost(host))}
    for host in ["alias","user@example.org","user@[::1]"] {check("Valid host accepted",RemoteWorkspace.validHost(host))}
    check("No shell injection",!FileManager.default.fileExists(atPath:root.appendingPathComponent("NEVER").path))
    check("No upload debris",try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy{!$0.hasPrefix(".orkhon-save.")})
    do {_ = try workspace.run("printf 'response exceeds limit'",limit:4);check("Bound response size",false)} catch {check("Bound response size",true)}
    do {_ = try workspace.run("while :; do printf 'error'; done >&2");check("Bound stderr stream",false)} catch {check("Bound stderr stream",true)}
    print("\(count) local SSH-operation checks passed; no network connection made.")
 }
}
