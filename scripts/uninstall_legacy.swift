// One-time cleanup for development builds, scoped strictly to Orkhon entries.
import AppKit
import CoreServices
import UniformTypeIdentifiers
let args=CommandLine.arguments
let fm=FileManager.default
let domain="com.apple.LaunchServices/com.apple.launchservices.secure"
func preferences() throws -> [String:Any] {
 let p=Process(),pipe=Pipe();p.executableURL=URL(fileURLWithPath:"/usr/bin/defaults");p.arguments=["export",domain,"-"];p.standardOutput=pipe
 try p.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
 guard p.terminationStatus==0 else {throw NSError(domain:"OrkhonCleanup",code:1)}
 return try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] ?? [:]
}
func run(_ executable:String,_ arguments:[String]) throws {
 let p=Process();p.executableURL=URL(fileURLWithPath:executable);p.arguments=arguments;try p.run();p.waitUntilExit()
 guard p.terminationStatus==0 else {throw NSError(domain:"OrkhonCleanup",code:Int(p.terminationStatus))}
}
func save<T:Encodable>(_ value:T,_ path:String)throws {let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];try e.encode(value).write(to:URL(fileURLWithPath:path),options:.atomic)}
if args.count > 1 && args[1] == "running" {
 for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier?.hasPrefix("app.orkhon.") == true { print("\(app.processIdentifier) \(app.bundleURL?.path ?? "unknown")") }
} else if args.count > 1 && args[1] == "clean-handlers" {
 let old=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
 let prefs=try preferences();let handlers=prefs["LSHandlers"] as? [[String:Any]] ?? []
 // Capture the complete preference list before touching only our role values.
 let snapshot=try PropertyListSerialization.data(fromPropertyList:handlers,format:.xml,options:0)
 try snapshot.write(to:URL(fileURLWithPath:args[3]),options:.atomic)
 var removed=0
 let cleaned=handlers.compactMap { record -> [String:Any]? in
  var record=record;var changed=false
  for key in ["LSHandlerRoleAll","LSHandlerRoleEditor","LSHandlerRoleViewer","LSHandlerRoleShell"] {
   if let value=record[key] as? String,value.lowercased().hasPrefix("app.orkhon.") {record.removeValue(forKey:key);removed+=1;changed=true}
  }
  if changed && !record.keys.contains(where:{$0.hasPrefix("LSHandlerRole")}) {return nil}
  return record
 }
 var updated=prefs;updated["LSHandlers"]=cleaned
 let file=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("orkhon-handlers-"+UUID().uuidString+".plist")
 try PropertyListSerialization.data(fromPropertyList:updated,format:.xml,options:0).write(to:file);defer{try? fm.removeItem(at:file)}
 try run("/usr/bin/defaults",["import",domain,file.path])
 try? run("/usr/bin/killall",["-u",NSUserName(),"lsd"])
 // Valid pre-Orkhon handlers are restored through the system API. Self-referential
 // legacy backups are deliberately not treated as previous defaults.
 var statuses:[String:Int32]=[:]
 for (uti,bundle) in old where !bundle.isEmpty && !bundle.lowercased().hasPrefix("app.orkhon.") {
  statuses[uti]=LSSetDefaultRoleHandlerForContentType(uti as CFString,.all,bundle as CFString)
 }
 try save(statuses,args[4]);print("Removed \(removed) Orkhon role overrides; reapplied \(statuses.count) recorded previous handlers.")
} else if args.count > 1 && args[1] == "audit" {
 let prefs=try preferences();let handlers=prefs["LSHandlers"] as? [[String:Any]] ?? []
 print("Remaining Orkhon role overrides: \(handlers.filter{entry in entry.contains{key,value in key.hasPrefix("LSHandlerRole") && (value as? String)?.lowercased().hasPrefix("app.orkhon.")==true}}.count)")
 for ext in ["md","cpp","cp","hpp","html","htm","shtml","xhtml","svg","xml","txt","swift","py","js","ts","mts","m2ts","plist","ps","url","pxd","tpl","log","as"] {
  let type=UTType(filenameExtension:ext)
  let handler=type.flatMap{LSCopyDefaultRoleHandlerForContentType($0.identifier as CFString,.all)?.takeRetainedValue() as String?}
  print("\(ext): \(type?.identifier ?? "unknown") → \(handler ?? "automatic / unassigned")")
 }
 for scheme in ["http","https"] {print("\(scheme): \(LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() as String? ?? "none")")}
} else {fputs("Usage: uninstall_legacy running | clean-handlers backup.json snapshot.plist report.json | audit\n",stderr);exit(2)}
