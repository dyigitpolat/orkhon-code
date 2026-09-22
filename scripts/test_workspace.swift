import Foundation
@main struct Check {static func main() {
 let cases:[([String],String?)]=[([],nil),(["/tmp/a/f.swift"],"/tmp/a"),(["/tmp/a/f","/tmp/a/deep/x"],"/tmp/a"),(["/tmp/apple/f","/tmp/app/f"],"/tmp"),(["/one/x","/two/y"],"/")]
 for (paths,want) in cases {let got=WorkspacePaths.commonParent(of:paths.map{URL(fileURLWithPath:$0)})?.path;precondition(got==want,"\(String(describing:got)) != \(String(describing:want))")};print("5 common-parent checks passed")
}}
