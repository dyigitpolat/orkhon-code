import AppKit
import LumenCore

/// A native modal session must not wait for a Swift main-actor task that is
/// suspended by that same session. Deliver completion through its run-loop mode.
private final class RemoteSaveCompletion:NSObject,@unchecked Sendable {
    private let lock=NSLock()
    private var storedError:Error?
    var error:Error? {lock.lock();defer{lock.unlock()};return storedError}
    func finish(_ result:Result<Void,Error>) {
        lock.lock();if case .failure(let error)=result {storedError=error};lock.unlock()
        performSelector(onMainThread:#selector(stopProgress),with:nil,waitUntilDone:false,modes:[RunLoop.Mode.modalPanel.rawValue])
    }
    @MainActor @objc private func stopProgress() {NSApp.stopModal()}
}

extension EditorWindowController {
    @objc func connectRemote(_ sender:Any?) {
        if remote != nil {let a=NSAlert();a.messageText="Disconnect the current SSH workspace first.";a.runModal();return}
        guard window.attachedSheet == nil else{return}
        sshWindow=SSHConnectionPanel(parent:window,theme:theme) { [weak self] connection in
            guard let self else{connection.disconnect();return}
            self.remote=connection;self.tree?.isHidden=true;self.ensureRemoteTree();self.remoteTree?.setRoot(connection.directory);self.treeItem.isCollapsed=false
            if self.terminalItem.isCollapsed {self.toggleTerminal(nil)}
            self.terminal?.startRemoteSession(connection);self.sshWindow=nil;self.bringToFront()
        }
        sshWindow?.present(on:window)
    }

    func ensureRemoteTree() {
        guard let connection=remote,remoteTree == nil else{return}
        let panel=RemoteTreePanel(frame:treeHost.bounds,connection:connection);panel.autoresizingMask=[.width,.height];panel.applyTheme(theme)
        panel.onOpen = { [weak self] in self?.openRemoteFile($0) };panel.onDisconnect = { [weak self] in self?.disconnectRemote(nil) };treeHost.addSubview(panel);remoteTree=panel
    }
    @objc func disconnectRemote(_ sender:Any?) {
        guard let connection=remote else{return}
        let targets=documents.filter{$0.remotePath != nil}
        for d in targets {if !confirmClose(d){return}}
        let alert=NSAlert();alert.messageText="Disconnect from \(connection.host)?";alert.informativeText="Remote tabs will close and remote terminal processes will end.";alert.addButton(withTitle:"Disconnect");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        targets.forEach{removeDocument($0)};terminal?.endRemoteSessions();coordinator?.releaseConnection(for:self);remote=nil;remoteTree?.removeFromSuperview();remoteTree=nil;tree?.isHidden=false;updateAutomaticWorkspace();ensureTree()
    }
    func openRemoteFile(_ path:String) {
        guard let connection=remote else{return}
        if let index=documents.firstIndex(where:{$0.remotePath==path}) {selectDocument(index);return}
        let d=DocumentTab();d.remotePath=path;d.loading=true;d.editor.send(2171,w:1,l:0);documents.append(d);configureEditor(d);selectDocument(documents.count-1)
        Task { [weak self,weak d] in
            let result=await Task.detached {Result {try DocumentStorage.decode(connection.read(path))}}.value
            guard let self,let d,self.remote===connection,self.documents.contains(where:{$0===d}) else{return}
            d.loading=false
            switch result {
            case .success(let file):d.format=file;d.editor.send(2171,w:0,l:0);d.editor.text=file.text;d.editor.markSaved();d.language=LanguageRegistry.shared.language(for:URL(fileURLWithPath:path),text:String(file.text.prefix(200)));self.configureLanguage(d);self.updateStatus();self.rebuildTabs();self.revealSelectedTab();self.pane(for:d)?.updatePreview();self.updateFileMonitoring()
            case .failure(let error):self.showError(error);self.removeDocument(d)
            }
        }
    }
    func saveRemoteDocument(_ d:DocumentTab)->Bool {
        guard let connection=remote,let path=d.remotePath,let format=d.format else{return false}
        do {
            let data=try DocumentStorage.encodedData(d.editor.text,format:format)
            let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:360,height:120),styleMask:[.titled],backing:.buffered,defer:false);panel.title="Saving to \(connection.host)";panel.isReleasedWhenClosed=false;if automatedTesting {panel.alphaValue=0;panel.ignoresMouseEvents=true}
            let label=NSTextField(labelWithString:"Saving \(d.title)…");label.frame=NSRect(x:24,y:68,width:310,height:22);label.lineBreakMode = .byTruncatingMiddle
            let progress=NSProgressIndicator(frame:NSRect(x:24,y:28,width:310,height:18));progress.style = .bar;progress.isIndeterminate=true;progress.startAnimation(nil)
            panel.contentView?.addSubview(label);panel.contentView?.addSubview(progress);panel.center();window.addChildWindow(panel,ordered:.above)
            let completion=RemoteSaveCompletion()
            DispatchQueue.global(qos:.userInitiated).async {
                completion.finish(Result{try connection.write(path,data:data,expected:format.originalData)})
            }
            NSApp.runModal(for:panel);window.removeChildWindow(panel);panel.orderOut(nil)
            if let failure=completion.error {throw failure}
            d.format=try DocumentStorage.decode(data);d.baselineChanged=false;d.externalChange=nil;d.externalHighlights=nil;d.externalAnchors=[];d.editor.clearExternalAnnotations();for marker in [24,25,26] {d.editor.send(2045,w:marker,l:0)};d.editor.markSaved();clearRecovery(d);rebuildTabs();updateStatus();return true
        } catch let error as RemoteFailure where error.exitStatus==73 {requestExternalReview(d);return false}
        catch {showError(error);return false}
    }
}
