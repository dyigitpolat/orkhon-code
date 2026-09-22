import AppKit
import CoreServices
import UniformTypeIdentifiers
let destination=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Orkhon Editor/Installation Defaults.json")
if !FileManager.default.fileExists(atPath:destination.path) {
    var saved:[String:String]=[:]
    for identifier in AssociationPolicy.catalog.keys {
        let handler=LSCopyDefaultRoleHandlerForContentType(identifier as CFString,.all)?.takeRetainedValue() as String? ?? ""
        if !handler.hasPrefix("app.orkhon.") {saved[identifier]=handler}
    }
    try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    try JSONEncoder().encode(saved).write(to:destination,options:.atomic)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
}
