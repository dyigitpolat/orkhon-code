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
    let file:TextFile
    let localText:String
    let merge:ExternalMerge?
    let error:String?
}

@MainActor
final class ExternalChangeReview:NSWindowController,NSTableViewDataSource,NSTableViewDelegate {
    private let change:ExternalChange,theme:Theme
    private var choices:[Int:Int]=[:]
    private let table=NSTableView(),diff=LMEditorView(frame:.zero)
    private let apply=PillButton(title:"Apply merge",target:nil,action:nil)
    private let status=NSTextField(labelWithString:"")
    private let onApply:(String)->Void
    init(parent:NSWindow,title:String,change:ExternalChange,theme:Theme,onApply:@escaping (String)->Void) {
        self.change=change;self.theme=theme;self.onApply=onApply
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:960,height:600),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:panel);panel.title="Review external changes";panel.titleVisibility = .hidden;panel.titlebarAppearsTransparent=true;panel.isReleasedWhenClosed=false;panel.appearance=parent.effectiveAppearance
        let content=Surface();content.color(theme.background);panel.contentView=content
        let heading=NSTextField(labelWithString:"Review changes · "+title);heading.font = .systemFont(ofSize:21,weight:.semibold);heading.textColor=theme.foreground;heading.lineBreakMode = .byTruncatingMiddle;heading.frame=NSRect(x:24,y:542,width:910,height:34);content.addSubview(heading)
        let detail=NSTextField(labelWithString:"Green lines were added on disk. Red lines were removed. Choose how to resolve each overlapping edit.")
        detail.font = .systemFont(ofSize:12);detail.textColor=NSColor(hex:theme.muted);detail.frame=NSRect(x:26,y:514,width:904,height:22);content.addSubview(detail)
        diff.frame=NSRect(x:24,y:84,width:486,height:418);diff.text=change.merge?.diff ?? change.file.text;diff.fontSize=12;diff.wordWrap=false;diff.applyPalette(theme.palette);diff.setLexer("diff",keywords:[],properties:[:]);diff.send(2171,w:1,l:0);content.addSubview(diff)
        diff.send(2040,w:24,l:22);diff.send(2042,w:24,l:0x709030);diff.send(2476,w:24,l:60)
        diff.send(2040,w:25,l:22);diff.send(2042,w:25,l:0x5050C0);diff.send(2476,w:25,l:60)
        for (index,line) in diff.text.components(separatedBy:"\n").enumerated() {
            if line.hasPrefix("+") && !line.hasPrefix("+++") {diff.send(2043,w:index,l:24)}
            if line.hasPrefix("-") && !line.hasPrefix("---") {diff.send(2043,w:index,l:25)}
        }
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("conflicts"));column.width=404;table.addTableColumn(column);table.headerView=nil;table.rowHeight=153;table.intercellSpacing=NSSize(width:0,height:8);table.backgroundColor=theme.background;table.dataSource=self;table.delegate=self;table.selectionHighlightStyle = .none
        let scroll=NSScrollView(frame:NSRect(x:528,y:84,width:408,height:418));scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false;content.addSubview(scroll)
        if change.merge?.conflicts.isEmpty == true {
            let label=NSTextField(wrappingLabelWithString:"No overlapping edits.\n\nOrkhon can combine your edits with the disk changes automatically.");label.textColor=theme.foreground;label.frame=NSRect(x:548,y:350,width:350,height:120);content.addSubview(label)
        }
        if let error=change.error {let label=NSTextField(wrappingLabelWithString:error);label.frame=NSRect(x:540,y:280,width:365,height:170);label.textColor=theme.foreground;content.addSubview(label)}
        let later=PillButton(title:"Review later",target:self,action:#selector(dismissReview));later.frame=NSRect(x:24,y:24,width:110,height:34)
        let mine=PillButton(title:"Keep my edits",target:self,action:#selector(keepMine));mine.frame=NSRect(x:145,y:24,width:124,height:34)
        let disk=PillButton(title:"Use disk version",target:self,action:#selector(useDisk));disk.frame=NSRect(x:280,y:24,width:138,height:34)
        apply.target=self;apply.action=#selector(applyMerge);apply.frame=NSRect(x:766,y:24,width:170,height:34);apply.state = .on
        for b in [later,mine,disk,apply] {b.accent=theme.accentColor;b.foreground=theme.foreground;b.font = .systemFont(ofSize:12,weight:.medium);content.addSubview(b)}
        status.frame=NSRect(x:436,y:32,width:320,height:18);status.textColor=NSColor(hex:theme.muted);status.font = .systemFont(ofSize:11);content.addSubview(status);updateStatus()
    }
    required init?(coder:NSCoder) {fatalError("Use init(parent:title:change:theme:onApply:)")}
    func present(on parent:NSWindow) {if let window {parent.beginSheet(window)}}
    func numberOfRows(in tableView:NSTableView)->Int {change.merge?.conflicts.count ?? 0}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard let conflict=change.merge?.conflicts[row] else{return nil}
        let cell=Surface();cell.color(theme.panelColor);cell.layer?.cornerRadius=8
        let heading=NSTextField(labelWithString:"Conflict \(row+1)");heading.font = .systemFont(ofSize:12,weight:.semibold);heading.textColor=theme.foreground;heading.frame=NSRect(x:12,y:128,width:370,height:18);cell.addSubview(heading)
        for (index,text) in [conflict.mine,conflict.disk].enumerated() {
            let label=NSTextField(wrappingLabelWithString:(index==0 ? "YOURS  ":"DISK   ")+String(text.prefix(240)).trimmingCharacters(in:.newlines))
            label.font = .monospacedSystemFont(ofSize:10,weight:.regular);label.textColor=index==0 ? theme.foreground:theme.accentColor;label.maximumNumberOfLines=2;label.lineBreakMode = .byTruncatingTail;label.frame=NSRect(x:12,y:85-CGFloat(index)*39,width:368,height:34);label.toolTip=text;cell.addSubview(label)
        }
        for (index,title) in ["Keep mine","Use disk","Both"].enumerated() {
            let button=PillButton(title:title,target:self,action:#selector(choose(_:)));button.tag=row*3+index;button.state=choices[row]==index ? .on:.off;button.accent=theme.accentColor;button.foreground=theme.foreground;button.font = .systemFont(ofSize:11);button.frame=NSRect(x:12+CGFloat(index)*122,y:10,width:112,height:27);cell.addSubview(button)
        }
        return cell
    }
    @objc private func choose(_ sender:NSButton) {choices[sender.tag/3]=sender.tag%3;table.reloadData(forRowIndexes:IndexSet(integer:sender.tag/3),columnIndexes:IndexSet(integer:0));updateStatus()}
    private func updateStatus() {let count=change.merge?.conflicts.count ?? 0;status.stringValue="\(choices.count) of \(count) conflicts resolved";apply.isEnabled=change.merge != nil && choices.count==count}
    @objc private func applyMerge() {if let result=change.merge?.resolved(choices) {dismissReview();onApply(result)}}
    @objc private func keepMine() {let mine=change.merge.flatMap{$0.resolved(Dictionary(uniqueKeysWithValues:$0.conflicts.indices.map{($0,0)}))} ?? change.localText;dismissReview();onApply(mine)}
    @objc private func useDisk() {dismissReview();onApply(change.file.text)}
    @objc private func dismissReview() {if let window {window.sheetParent?.endSheet(window);window.orderOut(nil)}}
}

extension EditorWindowController {
    func updateFileMonitoring(rearm:Bool=false) {
        fileMonitor.onChange = { [weak self] in self?.scheduleExternalCheck() }
        fileMonitor.update(documents.filter{!$0.isWelcome && $0.remotePath==nil}.compactMap{$0.url},rearm:rearm)
    }
    func scheduleExternalCheck() {
        externalCheck?.cancel();let work=DispatchWorkItem { [weak self] in self?.checkExternalChanges();self?.updateFileMonitoring(rearm:true) }
        externalCheck=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
    }
    func checkExternalChanges() {
        for d in documents where d.url != nil && d.remotePath==nil && !d.isWelcome && !d.loading && !d.checkingExternal {
            guard let url=d.url,let old=d.format else{continue};d.checkingExternal=true
            let modified=d.isModified,local=d.editor.text
            ioQueue.async { [weak self,weak d] in
                let disk=try? DocumentStorage.read(url)
                let changed=disk.map{$0.originalData != old.originalData} ?? false
                let merge=changed && modified ? disk.map{file in Result{try ExternalMerge.compare(base:old.text,mine:local,disk:file.text)}}:nil
                DispatchQueue.main.async {
                    guard let self,let d else{return};d.checkingExternal=false
                    guard self.documents.contains(where:{$0===d}),let file=disk,changed,d.format?.originalData==old.originalData else{return}
                    guard d.editor.text==local else {self.scheduleExternalCheck();return}
                    if !modified && !d.isModified {
                        let line=d.editor.currentLine;d.loading=true;d.format=file;d.editor.text=file.text;d.editor.markSaved();d.editor.go(toLine:line);d.loading=false;d.externalChange=nil
                        self.pane(for:d)?.schedulePreview();self.updateStatus();self.rebuildTabs()
                    } else {
                        let result:ExternalMerge?,error:String?
                        switch merge {case .success(let value):result=value;error=nil;case .failure(let failure):result=nil;error=failure.localizedDescription;case nil:result=nil;error=nil}
                        d.externalChange=ExternalChange(file:file,localText:local,merge:result,error:error)
                        if let result,result.conflicts.isEmpty,let merged=result.resolved([:]) {self.acceptExternalChange(d,text:merged,change:d.externalChange!)}
                        else {self.markConflicts(d);self.updateStatus();self.layoutEditor()}
                    }
                }
            }
        }
    }
    func pane(for d:DocumentTab)->EditorPane? {firstPane.document === d ? firstPane:(editorIsSplit && secondPane.document === d ? secondPane:nil)}
    func markConflicts(_ d:DocumentTab) {
        let e=d.editor;e.send(2045,w:26,l:0);e.send(2040,w:26,l:22);e.send(2042,w:26,l:0x4080C0);e.send(2476,w:26,l:70)
        for conflict in d.externalChange?.merge?.conflicts ?? [] {
            let count=e.send(2154,w:0,l:0)
            let first=min(max(0,count-1),conflict.localStartLine)
            for row in first..<min(count,first+conflict.localLineCount) {e.send(2043,w:row,l:26)}
        }
    }

    @objc func reviewExternalChange(_ sender:Any?) {
        guard let d=current,let change=d.externalChange,window.attachedSheet==nil else{return}
        if change.localText != d.editor.text {scheduleExternalCheck();return}
        externalReview=ExternalChangeReview(parent:window,title:d.title,change:change,theme:theme) { [weak self,weak d] text in
            guard let self,let d else{return}
            guard d.editor.text==change.localText else {self.scheduleExternalCheck();return}
            self.acceptExternalChange(d,text:text,change:change)
        }
        externalReview?.present(on:window)
    }
    func acceptExternalChange(_ d:DocumentTab,text:String,change:ExternalChange) {
        // Adopts a new disk baseline without destroying the working buffer's undo stack.
        d.loading=true;d.editor.send(2160,w:0,l:-1);d.editor.insertRecoveredText(text);d.format=change.file
        d.baselineChanged=text != change.file.text
        if !d.baselineChanged {d.editor.markSaved()}
        d.loading=false;d.externalChange=nil;d.editor.send(2045,w:26,l:0)
        pane(for:d)?.schedulePreview();scheduleRecovery(d);rebuildTabs();updateStatus();layoutEditor()
    }
}
