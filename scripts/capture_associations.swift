import AppKit
import CoreServices
import UniformTypeIdentifiers
let destination=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Orkhon Editor/Installation Defaults.json")
// Upgrades add missing formats while preserving the earliest recorded handlers.
var saved=(try? Data(contentsOf:destination)).flatMap{try? JSONDecoder().decode([String:String].self,from:$0)} ?? [:]
let identifiers=Set(AssociationPolicy.catalog.keys).union(AssociationPolicy.sourceExtensions.compactMap{UTType(filenameExtension:$0)?.identifier})
for identifier in identifiers where saved[identifier] == nil {
    let handler=LSCopyDefaultRoleHandlerForContentType(identifier as CFString,.all)?.takeRetainedValue() as String? ?? ""
    if !handler.hasPrefix("app.orkhon.") {saved[identifier]=handler}
}
try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
try JSONEncoder().encode(saved).write(to:destination,options:.atomic)
try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
