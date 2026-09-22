import Foundation
import Darwin

public struct MergeConflict:Sendable {
    public let mine:String,disk:String
    public let localStartLine:Int,localLineCount:Int
}
public enum MergePart:Sendable {case text(String),conflict(Int)}
public struct ExternalHunk:Sendable {
    public let current:String,external:String,original:String
    public let localStartLine:Int,localLineCount:Int
    public let conflictIndex:Int?
    public let baseStartLine:Int
}
public struct ExternalMerge:Sendable {
    public let parts:[MergePart],conflicts:[MergeConflict],diff:String
    public let changes:[ExternalHunk]
    private let mineFinalNewline:Bool,diskFinalNewline:Bool,baseFinalNewline:Bool
    /// Apply only explicitly chosen hunks; every unchosen span retains the exact
    /// working version. This supports immediate, individual inline decisions.
    public func applyingHunks(_ choices:[Int:Int],to mine:String)->String? {
        let source=Self.lines(mine)
        var result="",cursor=0,finalNewline=mineFinalNewline
        for (index,hunk) in changes.enumerated() {
            guard let choice=choices[index] else{continue}
            guard (0...2).contains(choice) else{return nil}
            let start=hunk.localStartLine,end=start+(hunk.current.isEmpty ? 0:hunk.current.utf8.filter{$0==10}.count)
            guard start>=cursor,end<=source.count else{return nil}
            result+=source[cursor..<start].joined()
            result+=choice==0 ? hunk.current:(choice==1 ? hunk.external:hunk.current+hunk.external)
            cursor=end
            if end==source.count {finalNewline=choice==0 ? mineFinalNewline:diskFinalNewline}
        }
        result+=source[cursor...].joined()
        if !finalNewline,result.hasSuffix("\n") {result.removeLast();if result.hasSuffix("\r"){result.removeLast()}}
        return result
    }
    public func resolved(_ choices:[Int:Int])->String? {
        var result=""
        for part in parts {
            switch part {
            case .text(let text):result+=text
            case .conflict(let index):
                guard let choice=choices[index],(0...2).contains(choice) else{return nil};let c=conflicts[index]
                result += choice==0 ? c.mine:(choice==1 ? c.disk:c.mine+c.disk)
            }
        }
        var finalNewline=mineFinalNewline==baseFinalNewline ? diskFinalNewline:mineFinalNewline
        if let last=parts.last,case .conflict(let index)=last {finalNewline=choices[index]==0 ? mineFinalNewline:diskFinalNewline}
        if !finalNewline,result.hasSuffix("\n") {result.removeLast();if result.hasSuffix("\r"){result.removeLast()}}
        return result
    }
    /// Uses the OS diff engine for line changes, then groups intersecting edit ranges.
    public static func compare(base:String,mine:String,disk:String)throws->ExternalMerge {
        guard max(base.utf8.count,mine.utf8.count,disk.utf8.count)<=8*1024*1024 else {throw MergeError("Automatic merge supports files up to 8 MB. Save your edits as a copy before reloading this file.")}
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("orkhon-merge-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:folder)}
        for (name,value) in [("base",base),("mine",mine),("disk",disk)] {try Data((value.isEmpty || value.hasSuffix("\n") ? value:value+"\n").utf8).write(to:folder.appendingPathComponent(name));try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:folder.appendingPathComponent(name).path)}
        let baseLines=lines(base)
        let mineChanges=try edits(from:base,to:mine,folder:folder,name:"mine")
        let diskChanges=try edits(from:base,to:disk,folder:folder,name:"disk")
        let diff=try run("/usr/bin/diff",["-u","-L","Saved version","-L","Changed on disk",folder.appendingPathComponent("base").path,folder.appendingPathComponent("disk").path],in:folder)
        var allEdits:[TaggedEdit]=[]
        for edit in mineChanges {allEdits.append(TaggedEdit(side:0,edit:edit))}
        for edit in diskChanges {allEdits.append(TaggedEdit(side:1,edit:edit))}
        allEdits.sort { a,b in if a.edit.start==b.edit.start {return a.edit.end<b.edit.end};return a.edit.start<b.edit.start }
        var next=0
        var parts:[MergePart]=[],conflicts:[MergeConflict]=[],changes:[ExternalHunk]=[],cursor=0,localLine=0
        func append(_ text:String) {if !text.isEmpty {parts.append(.text(text))}}
        while next<allEdits.count {
            var group=[allEdits[next]];next+=1
            var endPosition=group[0].edit.end
            while next<allEdits.count,allEdits[next].edit.start<=endPosition {
                let candidate=allEdits[next]
                let overlapsGroup=candidate.edit.start<endPosition || (group[0].edit.start==endPosition && candidate.edit.start==endPosition)
                guard overlapsGroup else{break}
                group.append(candidate);next+=1;endPosition=max(endPosition,candidate.edit.end)
            }
            let start=group.map{$0.edit.start}.min()!,end=group.map{$0.edit.end}.max()!
            guard start>=cursor,end<=baseLines.count else{throw MergeError("Could not safely order external edits. Your working text has not changed.")}
            append(baseLines[cursor..<start].joined());localLine+=start-cursor
            let local=group.filter{$0.side==0}.map(\.edit),external=group.filter{$0.side==1}.map(\.edit)
            let mineText=applying(local,to:baseLines,start:start,end:end),diskText=applying(external,to:baseLines,start:start,end:end)
            if !external.isEmpty,mineText != diskText {
                changes.append(ExternalHunk(current:mineText,external:diskText,original:baseLines[start..<end].joined(),localStartLine:localLine,localLineCount:max(1,mineText.utf8.filter{$0==10}.count),conflictIndex:local.isEmpty ? nil:conflicts.count,baseStartLine:start))
            }
            if local.isEmpty {append(diskText)}
            else if external.isEmpty || mineText==diskText {append(mineText)}
            else {parts.append(.conflict(conflicts.count));conflicts.append(MergeConflict(mine:mineText,disk:diskText,localStartLine:localLine,localLineCount:max(1,mineText.utf8.filter{$0==10}.count)))}
            localLine+=mineText.utf8.filter{$0==10}.count;cursor=end
        }
        append(baseLines[cursor...].joined())
        return ExternalMerge(parts:parts,conflicts:conflicts,diff:diff,changes:changes,mineFinalNewline:mine.hasSuffix("\n"),diskFinalNewline:disk.hasSuffix("\n"),baseFinalNewline:base.hasSuffix("\n"))
    }
    private struct Edit {let start:Int,end:Int,replacement:String}
    private struct TaggedEdit {let side:Int,edit:Edit}
    private static func lines(_ text:String)->[String] {
        guard !text.isEmpty else{return []}
        var result=text.components(separatedBy:"\n")
        if result.last=="" {result.removeLast()}
        return result.map{$0+"\n"}
    }
    /// RCS edit scripts come from the OS diff engine. Content lines are length-framed,
    /// so literal conflict markers or diff-like source text cannot become control data.
    private static func edits(from base:String,to value:String,folder:URL,name:String)throws->[Edit] {
        let script=try run("/usr/bin/diff",["-n",folder.appendingPathComponent("base").path,folder.appendingPathComponent(name).path],in:folder)
        let records=script.components(separatedBy:"\n");var index=0,result:[Edit]=[]
        while index<records.count,!records[index].isEmpty {
            let header=records[index];index+=1
            let numbers=header.dropFirst().split(separator:" ").compactMap{Int($0)}
            guard numbers.count==2,numbers[0]>=0,numbers[1]>0 else{throw MergeError("Could not read the external edit script.")}
            let line=numbers[0],count=numbers[1]
            if header.first=="d" {
                guard line>0 else{throw MergeError("Invalid removed-line position.")}
                result.append(Edit(start:line-1,end:line-1+count,replacement:""))
            } else if header.first=="a" {
                guard index+count<=records.count else{throw MergeError("Incomplete added-line data.")}
                let text=records[index..<index+count].map{$0+"\n"}.joined();index+=count
                if let last=result.last,last.replacement.isEmpty,last.end==line {result.removeLast();result.append(Edit(start:last.start,end:last.end,replacement:text))}
                else {result.append(Edit(start:line,end:line,replacement:text))}
            } else {throw MergeError("Unknown external edit operation.")}
        }
        return result
    }
    private static func applying(_ edits:[Edit],to base:[String],start:Int,end:Int)->String {
        var result="",cursor=start
        for edit in edits.sorted(by:{$0.start<$1.start}) {result+=base[cursor..<edit.start].joined()+edit.replacement;cursor=edit.end}
        return result+base[cursor..<end].joined()
    }
    private static func run(_ executable:String,_ arguments:[String],in folder:URL)throws->String {
        let out=folder.appendingPathComponent("out"),err=folder.appendingPathComponent("err")
        FileManager.default.createFile(atPath:out.path,contents:nil,attributes:[.posixPermissions:0o600]);FileManager.default.createFile(atPath:err.path,contents:nil,attributes:[.posixPermissions:0o600])
        let stdout=try FileHandle(forWritingTo:out),stderr=try FileHandle(forWritingTo:err);defer{try? stdout.close();try? stderr.close()}
        let p=Process();p.executableURL=URL(fileURLWithPath:executable);p.arguments=arguments;p.standardInput=FileHandle.nullDevice;p.standardOutput=stdout;p.standardError=stderr
        try p.run();let deadline=Date().addingTimeInterval(8)
        while p.isRunning && Date()<deadline {Thread.sleep(forTimeInterval:0.01)}
        if p.isRunning {p.terminate();Thread.sleep(forTimeInterval:0.05);if p.isRunning {kill(p.processIdentifier,SIGKILL)};p.waitUntilExit();throw MergeError("Comparing this file took too long. Your edits have not changed.")}
        p.waitUntilExit();guard p.terminationStatus<=1 else {throw MergeError((try? String(contentsOf:err,encoding:.utf8)) ?? "Could not compare the file.")}
        return try String(contentsOf:out,encoding:.utf8)
    }
}
public struct MergeError:LocalizedError {public let message:String;public init(_ message:String){self.message=message};public var errorDescription:String? {message}}
