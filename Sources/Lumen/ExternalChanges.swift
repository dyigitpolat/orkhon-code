import AppKit
import EditorBridge
import LumenCore
import Darwin

final class FileChangeMonitor {
    private var sources:[String:DispatchSourceFileSystemObject]=[:]
    private let queue=DispatchQueue(label:"app.orkhon.file-watch",qos:.utility)
    var onChange:(()->Void)?
    func update(_ urls:[URL],rearm:Bool=false) {
        let paths=Set(urls.flatMap{[$0.path,$0.deletingLastPathComponent().path]})
        for path in Array(sources.keys) where rearm || !paths.contains(path) {sources.removeValue(forKey:path)?.cancel()}
        for path in paths where sources[path]==nil {
            let fd=open(path,O_EVTONLY|O_CLOEXEC);guard fd>=0 else{continue}
            let source=DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete,.attrib,.extend],queue:queue)
            source.setEventHandler { [weak self] in DispatchQueue.main.async {self?.onChange?()} }
            source.setCancelHandler {close(fd)};sources[path]=source;source.resume()
        }
    }
    deinit {sources.values.forEach{$0.cancel()}}
}

struct ExternalChange {
    let id=UUID()
    let file:TextFile
    var localText:String
    let originalLocalText:String
    var choices:[Int:Int]=[:]
    let merge:ExternalMerge?
    let error:String?
    init(file:TextFile,localText:String,merge:ExternalMerge?,error:String?) {
        self.file=file;self.localText=localText;self.originalLocalText=localText;self.merge=merge;self.error=error
    }
    var remainingCount:Int {(merge?.changes.count ?? 0)-choices.count}
    var remainingConflicts:Int {merge?.changes.enumerated().filter{choices[$0.offset]==nil && $0.element.conflictIndex != nil}.count ?? 0}
}
struct ExternalAnchor {let index:Int,line:Int,row:Int}


extension EditorWindowController {
    func updateFileMonitoring(rearm:Bool=false) {
        fileMonitor.onChange = { [weak self] in self?.scheduleExternalCheck() }
        fileMonitor.update(documents.filter{!$0.isWelcome && $0.remotePath==nil}.compactMap{$0.url},rearm:rearm)
        let needsPolling=remote != nil && documents.contains{$0.remotePath != nil}
        if needsPolling && remotePollTimer==nil {
            let timer=Timer(timeInterval:2,repeats:true) { [weak self] _ in Task { @MainActor in self?.checkRemoteChanges() } }
            RunLoop.main.add(timer,forMode:.common);remotePollTimer=timer
        } else if !needsPolling {remotePollTimer?.invalidate();remotePollTimer=nil}
    }
    func scheduleExternalCheck() {
        externalCheck?.cancel();let work=DispatchWorkItem { [weak self] in self?.checkExternalChanges();self?.updateFileMonitoring(rearm:true) }
        externalCheck=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work)
    }
    func checkExternalChanges() {
        for d in documents where d.url != nil && d.remotePath==nil && !d.isWelcome && !d.loading && !d.checkingExternal {
            guard let url=d.url,let old=d.format else{continue};d.checkingExternal=true
            let modified=d.isModified,local=d.editor.text
            ioQueue.async { [weak self,weak d] in
                let read=Result {try DocumentStorage.read(url,fallbackEncoding:old.encoding)}
                let file=try? read.get()
                let changed=file.map{$0.originalData != old.originalData} ?? false
                let merge=changed && modified ? file.map{file in Result{try ExternalMerge.compare(base:old.text,mine:local,disk:file.text)}}:nil
                DispatchQueue.main.async {
                    guard let self,let d else{return};d.checkingExternal=false
                    guard self.documents.contains(where:{$0===d}),d.format?.originalData==old.originalData else{return}
                    guard d.editor.text==local else {self.scheduleExternalCheck();return}
                    if let file,changed {self.receiveExternalFile(file,for:d,local:local,modified:modified,merge:merge)}
                    else if file != nil {self.clearRevertedExternalChange(d)}
                    else if d.externalReviewRequested {d.externalReviewRequested=false;if case .failure(let error)=read {self.showError(error)}}
                }
            }
        }
        checkRemoteChanges(force:documents.contains{$0.externalReviewRequested && $0.remotePath != nil})
    }
    /// One batched checksum request, no overlapping polls. Data crosses SSH only
    /// when a file actually changes; large workspaces use a slower ten-second poll.
    func checkRemoteChanges(force:Bool=false) {
        guard let connection=remote,!remotePollInFlight else{return}
        let docs=documents.filter{$0.remotePath != nil && !$0.loading && $0.format != nil}
        guard !docs.isEmpty else{return}
        let now=ProcessInfo.processInfo.systemUptime
        let interval:Double=docs.reduce(0){$0+($1.format?.originalData.count ?? 0)}>2*1024*1024 ? 10:2
        guard force || now-lastRemotePoll>=interval else{return}
        lastRemotePoll=now;remotePollInFlight=true
        let snapshots=docs.map{($0,$0.remotePath!,$0.format!)}
        let baselines=snapshots.map{($0.1,$0.2.originalData)}
        Task { [weak self] in
            let result=await Task.detached {Result {
                let hashes=try connection.checksums(baselines.map{$0.0})
                return Dictionary(baselines.map{($0.0,(hashes[$0.0],RemoteWorkspace.checksum($0.1)))},uniquingKeysWith:{$1})
            }}.value
            guard let self else{return};defer{self.remotePollInFlight=false}
            guard self.remote === connection else{return}
            switch result {
            case .failure(let error):self.remoteTree?.showMessage("Refresh unavailable · "+error.localizedDescription)
            case .success(let hashes):
                for (d,path,old) in snapshots {
                    guard self.documents.contains(where:{$0===d}),!d.loading,!d.checkingExternal,d.format?.originalData==old.originalData else{continue}
                    let pair=hashes[path],digest=pair?.0
                    if digest==pair?.1 {self.clearRevertedExternalChange(d);continue}
                    let local=d.editor.text,modified=d.isModified
                    if let pending=d.externalChange,digest==RemoteWorkspace.checksum(pending.file.originalData),pending.localText==local {
                        if d.externalReviewRequested {self.showExternalReview(d)};continue
                    }
                    d.checkingExternal=true
                    let read=await Task.detached {Result {try DocumentStorage.decode(connection.read(path),fallbackEncoding:old.encoding)}}.value
                    let file=try? read.get()
                    let merge=modified ? await Task.detached {file.map{file in Result{try ExternalMerge.compare(base:old.text,mine:local,disk:file.text)}}}.value:nil
                    d.checkingExternal=false
                    guard self.remote === connection,self.documents.contains(where:{$0===d}),d.format?.originalData==old.originalData else{continue}
                    guard d.editor.text==local else{self.lastRemotePoll=0;continue}
                    if let file,file.originalData != old.originalData {self.receiveExternalFile(file,for:d,local:local,modified:modified,merge:merge)}
                    else if case .failure(let error)=read {
                        self.remoteTree?.showMessage(error.localizedDescription)
                        if d.externalReviewRequested {d.externalReviewRequested=false;self.showError(error)}
                    }
                }
            }
        }
    }
    func receiveExternalFile(_ file:TextFile,for d:DocumentTab,local:String,modified:Bool,merge:Result<ExternalMerge,Error>?) {
        if !modified && !d.isModified {
            let line=d.editor.currentLine;d.loading=true;d.format=file;d.baselineChanged=false;d.editor.text=file.text;d.editor.markSaved();d.editor.go(toLine:line);d.loading=false;d.externalChange=nil;d.externalHighlights=nil;d.externalReviewRequested=false
            d.editor.clearExternalAnnotations();for marker in [24,25,26] {d.editor.send(2045,w:marker,l:0)};d.externalAnchors=[];pane(for:d)?.updatePreview();updateStatus();rebuildTabs();return
        }
        if let pending=d.externalChange,pending.file.originalData==file.originalData,pending.localText==local {
            if d.externalReviewRequested {showExternalReview(d)};return
        }
        let result:ExternalMerge?,error:String?
        switch merge {case .success(let value):result=value;error=nil;case .failure(let failure):result=nil;error=failure.localizedDescription;case nil:result=nil;error=nil}
        let first=d.externalChange==nil
        let previous=d.externalChange
        var next=ExternalChange(file:file,localText:local,merge:result,error:error)
        if let previous,previous.file.originalData==file.originalData,let old=previous.merge,let result {
            for (index,hunk) in result.changes.enumerated() {
                if old.changes.enumerated().contains(where:{previous.choices[$0.offset]==0 && $0.element.baseStartLine==hunk.baseStartLine && $0.element.current==hunk.current && $0.element.external==hunk.external}) {next.choices[index]=0}
            }
        }
        // Independent edits are safe to merge immediately. Only overlapping edits
        // need a decision; the accepted additions/removals remain visible in place.
        if let result {for (index,hunk) in result.changes.enumerated() where hunk.conflictIndex==nil {next.choices[index]=1}}
        d.externalHighlights=nil;d.externalChange=next
        let text=result?.applyingHunks(next.choices,to:next.originalLocalText) ?? local
        if result != nil,next.remainingCount==0 {acceptExternalChange(d,text:text,change:next);return}
        if text != local {
            let line=d.editor.currentLine;d.loading=true;d.editor.send(2160,w:0,l:-1);d.editor.insertRecoveredText(text);d.editor.go(toLine:line);d.loading=false
            next.localText=text;d.externalChange=next;scheduleRecovery(d);rebuildTabs()
        }
        markConflicts(d)
        // Recomputing after further typing must not repeatedly interrupt editing.
        if first || d.externalReviewRequested {d.previewMode = .source}
        d.externalReviewRequested=false;pane(for:d)?.updatePreview();updateStatus();layoutEditor()
    }
    func clearRevertedExternalChange(_ d:DocumentTab) {
        d.externalReviewRequested=false
        guard d.externalChange != nil else{return}
        d.externalChange=nil;d.externalHighlights=nil;d.externalAnchors=[];d.editor.clearExternalAnnotations()
        for marker in [24,25,26] {d.editor.send(2045,w:marker,l:0)}
        pane(for:d)?.updatePreview();updateStatus();layoutEditor()
    }
    func pane(for d:DocumentTab)->EditorPane? {firstPane.document === d ? firstPane:(editorIsSplit && secondPane.document === d ? secondPane:nil)}
    func markConflicts(_ d:DocumentTab) {
        let e=d.editor;e.clearExternalAnnotations();d.externalAnchors=[]
        // Accepted additions are deliberately quieter than unresolved current lines.
        for (marker,color,alpha) in [(24,0x709030,28),(25,0x5050C0,68),(26,0x4080C0,65)] {
            e.send(2045,w:marker,l:0);e.send(2040,w:marker,l:22);e.send(2042,w:marker,l:color);e.send(2476,w:marker,l:alpha)
        }
        guard let change=d.externalChange ?? d.externalHighlights,let merge=change.merge else{return}
        let count=e.send(2154,w:0,l:0)
        var offset=0,annotations:[Int:(text:String,styles:Data)]=[:]
        func append(_ text:String,style:UInt8,line:Int) {
            guard !text.isEmpty else{return}
            var value=annotations[line] ?? ("",Data())
            value.text+=text;value.styles.append(Data(repeating:style,count:text.utf8.count));annotations[line]=value
        }
        func ghost(_ text:String)->String {
            let full=text.replacingOccurrences(of:"\r\n",with:"\n")
            var lines=full.components(separatedBy:"\n");if lines.last=="" {lines.removeLast()}
            return lines.map{$0+"\n"}.joined()
        }
        func highlight(_ first:Int,_ length:Int,_ marker:Int) {
            let end=min(count,first+length);if first<end {for row in max(0,first)..<end {e.send(2043,w:row,l:marker)}}
        }
        for (index,hunk) in merge.changes.enumerated() {
            let currentLines=hunk.current.utf8.filter{$0==10}.count,externalLines=hunk.external.utf8.filter{$0==10}.count
            let first=min(max(0,count-1),max(0,hunk.localStartLine+offset))
            if let choice=change.choices[index] {
                if choice==1 {
                    highlight(first,externalLines,24)
                    // Removed text is read-only history, never part of the buffer.
                    let anchor=first>0 ? first-1:min(count-1,first+max(0,externalLines-1))
                    append(ghost(hunk.current),style:251,line:max(0,anchor))
                } else if choice==2 {highlight(first+currentLines,externalLines,24)}
                offset+=(choice==0 ? currentLines:choice==1 ? externalLines:currentLines+externalLines)-currentLines
                continue
            }
            highlight(first,currentLines,25)
            let anchor=hunk.current.isEmpty ? max(0,first-1):min(count-1,first+max(0,currentLines-1))
            let row=annotations[anchor]?.text.utf8.filter{$0==10}.count ?? 0
            d.externalAnchors.append(ExternalAnchor(index:index,line:anchor,row:row))
            append(" \n \n",style:252,line:anchor)
            append(ghost(hunk.external),style:253,line:anchor)
        }
        d.externalAnchors.sort{($0.line,$0.row)<($1.line,$1.row)}
        for (line,value) in annotations {e.setExternalAnnotation(value.text,styles:value.styles,atLine:line)}
    }
    func chooseExternalHunk(_ d:DocumentTab,index:Int,value:Int,changeID:UUID) {
        guard var change=d.externalChange,change.id==changeID,change.localText==d.editor.text,
              let merge=change.merge,merge.changes.indices.contains(index),(0...2).contains(value) else {requestExternalReview(d);return}
        change.choices[index]=value
        guard let text=merge.applyingHunks(change.choices,to:change.originalLocalText) else{return}
        if change.remainingCount==0 {acceptExternalChange(d,text:text,change:change);return}
        let line=d.editor.currentLine
        d.loading=true
        if text != change.localText {d.editor.send(2160,w:0,l:-1);d.editor.insertRecoveredText(text);d.editor.go(toLine:line)}
        change.localText=text;d.externalChange=change;d.loading=false
        markConflicts(d);pane(for:d)?.updatePreview();scheduleRecovery(d);rebuildTabs();updateStatus();layoutEditor();d.editor.focus()
    }
    func requestExternalReview(_ d:DocumentTab) {
        d.externalReviewRequested=true
        if d.externalChange != nil {showExternalReview(d)}
        else {status.stringValue="Reading external changes…";checkExternalChanges()}
    }
    func showExternalReview(_ d:DocumentTab) {
        guard d.externalChange != nil else{return};d.externalReviewRequested=false;d.previewMode = .source
        pane(for:d)?.updatePreview();layoutEditor()
        let line=d.editor.currentLine-1
        if let anchor=d.externalAnchors.first(where:{$0.line>line}) ?? d.externalAnchors.first {d.editor.go(toLine:anchor.line+1)}
        d.editor.focus()
    }
    @objc func reviewExternalChange(_ sender:Any?) {
        guard let d=current,let change=d.externalChange else{return}
        if change.merge==nil {_ = saveDocument(d,asNew:true);return}
        if change.localText != d.editor.text {requestExternalReview(d);scheduleExternalCheck();return}
        showExternalReview(d)
    }
    func acceptExternalChange(_ d:DocumentTab,text:String,change:ExternalChange) {
        guard d.editor.text==change.localText,d.externalChange?.id==change.id else {requestExternalReview(d);return}
        let line=d.editor.currentLine;d.loading=true
        if text != change.localText {d.editor.send(2160,w:0,l:-1);d.editor.insertRecoveredText(text);d.editor.go(toLine:line)}
        d.format=change.file
        d.baselineChanged=text != change.file.text
        if !d.baselineChanged {d.editor.markSaved()}
        var highlights=change;highlights.localText=text
        d.loading=false;d.externalChange=nil;d.externalHighlights=highlights;markConflicts(d)
        pane(for:d)?.updatePreview();scheduleRecovery(d);rebuildTabs();updateStatus();layoutEditor();d.editor.focus()
    }
}
