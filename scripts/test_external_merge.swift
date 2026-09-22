import Foundation

@main struct MergeTests {
    static func main() {
        var passed=0,failures:[String]=[]
        func check(_ name:String,_ value:Bool) {if value {passed+=1} else {failures.append(name)}}
        do {
            let clean=try ExternalMerge.compare(base:"first\nsecond\nthird\n",mine:"local\nsecond\nthird\n",disk:"first\nsecond\nexternal\n")
            check("Independent edits merge",clean.conflicts.isEmpty && clean.resolved([:])=="local\nsecond\nexternal\n")
            let conflict=try ExternalMerge.compare(base:"a\nb\nc\n",mine:"a\nlocal\nc\n",disk:"a\nremote\nc\n")
            check("Unresolved conflict cannot be applied",conflict.resolved([:])==nil)
            check("Keep mine",conflict.resolved([0:0])=="a\nlocal\nc\n")
            check("Use disk",conflict.resolved([0:1])=="a\nremote\nc\n")
            check("Use both",conflict.resolved([0:2])=="a\nlocal\nremote\nc\n")
            check("Diff exposes additions and removals",conflict.diff.contains("+remote") && conflict.diff.contains("-b"))
            let noNewline=try ExternalMerge.compare(base:"a",mine:"b",disk:"c")
            check("Missing final newline preserved for mine",noNewline.resolved([0:0])=="b")
            check("Missing final newline preserved for disk",noNewline.resolved([0:1])=="c")
            let windows=try ExternalMerge.compare(base:"a\r\nb\r\n",mine:"a\r\nlocal\r\n",disk:"a\r\ndisk\r\n")
            check("CRLF preserved for mine",windows.resolved([0:0])=="a\r\nlocal\r\n")
            check("CRLF preserved for disk",windows.resolved([0:1])=="a\r\ndisk\r\n")
            let unicode=try ExternalMerge.compare(base:"你好\nβeta\n",mine:"你好\nβeta\nlocal\n",disk:"🌊\nβeta\n")
            check("Unicode remains exact",unicode.resolved([:])=="🌊\nβeta\nlocal\n")
            let deletion=try ExternalMerge.compare(base:"a\nb\n",mine:"a\n",disk:"a\nB\n")
            check("Deletion conflict keeps removal",deletion.resolved([0:0])=="a\n")
            check("Deletion conflict accepts disk",deletion.resolved([0:1])=="a\nB\n")
            let empty=try ExternalMerge.compare(base:"",mine:"",disk:"created\n")
            check("Empty file gains external content",empty.resolved([:])=="created\n")
            let identical=try ExternalMerge.compare(base:"old",mine:"new",disk:"new")
            check("Identical concurrent edits need no conflict",identical.conflicts.isEmpty && identical.resolved([:])=="new")
            let markers="<<<<<<< literal\n=======\n>>>>>>> literal\n"
            let literal=try ExternalMerge.compare(base:markers,mine:markers,disk:markers+"new\n")
            check("Literal marker text is preserved",literal.resolved([:])==markers+"new\n")
            do {_ = try ExternalMerge.compare(base:"",mine:String(repeating:"x",count:8*1024*1024+1),disk:"");check("Large merge bounded",false)} catch {check("Large merge bounded",true)}
        } catch {failures.append(error.localizedDescription)}
        print("\(passed) external-merge checks passed")
        failures.forEach{fputs("FAIL: \($0)\n",stderr)}
        exit(failures.isEmpty ? 0:1)
    }
}
