import Foundation

@main struct MergeTests {
    static func main() {
        var passed=0,failures:[String]=[]
        func check(_ name:String,_ value:Bool) {if value {passed+=1} else {failures.append(name)}}
        do {
            let clean=try ExternalMerge.compare(base:"first\nsecond\nthird\n",mine:"local\nsecond\nthird\n",disk:"first\nsecond\nexternal\n")
            check("Independent edits merge",clean.conflicts.isEmpty && clean.resolved([:])=="local\nsecond\nexternal\n")
            check("Independent external replacement remains reviewable",clean.changes.count==1 && clean.changes[0].current=="third\n" && clean.changes[0].external=="external\n" && clean.changes[0].conflictIndex==nil)
            let addition=try ExternalMerge.compare(base:"a\nb\nc\n",mine:"local\nb\nc\n",disk:"a\nb\nc\nadded\n")
            check("External insertion exposes full new lines",addition.changes.count==1 && addition.changes[0].current.isEmpty && addition.changes[0].external=="added\n" && addition.changes[0].localStartLine==3)
            let removal=try ExternalMerge.compare(base:"a\nb\nc\n",mine:"local\nb\nc\n",disk:"a\nb\n")
            check("External deletion exposes removed lines",removal.changes.count==1 && removal.changes[0].current=="c\n" && removal.changes[0].external.isEmpty && removal.changes[0].localLineCount==1)
            check("Inline external choice changes only that hunk",clean.applyingHunks([0:1],to:"local\nsecond\nthird\n")=="local\nsecond\nexternal\n")
            check("Inline current choice preserves working bytes",clean.applyingHunks([0:0],to:"local\nsecond\nthird\n")=="local\nsecond\nthird\n")
            let several=try ExternalMerge.compare(base:"a\nb\nc\nd\ne\n",mine:"A\nb\nc\nd\ne\n",disk:"X\nb\nc\nd\nE\n")
            check("First inline decision leaves other spans untouched",several.applyingHunks([0:1],to:"A\nb\nc\nd\ne\n")=="X\nb\nc\nd\ne\n")
            check("Independent hunk can be kept while accepting conflict",several.applyingHunks([0:1,1:0],to:"A\nb\nc\nd\ne\n")=="X\nb\nc\nd\ne\n")
            let conflict=try ExternalMerge.compare(base:"a\nb\nc\n",mine:"a\nlocal\nc\n",disk:"a\nremote\nc\n")
            check("Conflict hunk maps to its full current and external spans",conflict.changes.count==1 && conflict.changes[0].current=="local\n" && conflict.changes[0].external=="remote\n" && conflict.changes[0].conflictIndex==0)
            check("Unresolved conflict cannot be applied",conflict.resolved([:])==nil)
            check("Keep mine",conflict.resolved([0:0])=="a\nlocal\nc\n")
            check("Use disk",conflict.resolved([0:1])=="a\nremote\nc\n")
            check("Use both",conflict.resolved([0:2])=="a\nlocal\nremote\nc\n")
            check("Diff exposes additions and removals",conflict.diff.contains("+remote") && conflict.diff.contains("-b"))
            let noNewline=try ExternalMerge.compare(base:"a",mine:"b",disk:"c")
            check("Inline missing newline preserved",noNewline.applyingHunks([0:1],to:"b")=="c")
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
