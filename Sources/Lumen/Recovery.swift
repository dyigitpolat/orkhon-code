import AppKit
import LumenCore
struct RecoveryRecord:Codable {let id:String;let path:String?;let text:String;let originalData:Data?;let date:Date}
struct SessionRecord:Codable {let paths:[String];let folder:String?;var pinnedPaths:[String]?}
extension EditorWindowController {
    func scheduleRecovery(_ d:DocumentTab) {
        d.recoveryWork?.cancel()
        guard d.isModified else {clearRecovery(d);return}
        let work=DispatchWorkItem { [weak self,weak d] in
            guard let self,let d,d.isModified else{return}
            let record=RecoveryRecord(id:d.id,path:d.url?.path,text:d.editor.text,originalData:d.format?.originalData,date:Date())
            let url=self.recoveryURL.appendingPathComponent(d.id+".json")
            self.recoveryQueue.async {
                do {try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let data=try JSONEncoder().encode(record);try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)} catch {NSLog("Recovery write failed: %@",error.localizedDescription)}
            }
        }
        d.recoveryWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.8,execute:work)
    }
    func clearRecovery(_ d:DocumentTab) {
        d.recoveryWork?.cancel();d.recoveryWork=nil
        let url=recoveryURL.appendingPathComponent(d.id+".json")
        recoveryQueue.async {try? FileManager.default.removeItem(at:url)}
    }
    func persistSession() {
        guard !restoring else{return}
        coordinator?.persistSession()
    }
    var sessionRecord:SessionRecord {SessionRecord(paths:documents.filter{!$0.isWelcome && $0.remotePath == nil}.compactMap{$0.url?.path},folder:manualWorkspace ? workspaceURL?.path:nil,pinnedPaths:documents.filter{$0.pinned}.compactMap{$0.url?.path})}

    func restoreSession() {
        let directory=recoveryURL,session=sessionURL
        recoveryQueue.async { [weak self] in
            let data=try? Data(contentsOf:session)
            let archive=data.flatMap{try? JSONDecoder().decode(SessionArchive.self,from:$0)}
            let oldSession=archive?.windows.first ?? data.flatMap{try? JSONDecoder().decode(SessionRecord.self,from:$0)}
            let urls=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []
            let records=urls.filter{$0.pathExtension=="json"}.compactMap{url -> (URL,RecoveryRecord)? in guard let data=try? Data(contentsOf:url),let r=try? JSONDecoder().decode(RecoveryRecord.self,from:data) else{return nil};return(url,r)}.sorted{$0.1.date<$1.1.date}
            DispatchQueue.main.async {
                guard let self else{return};self.restoring=true
                if let folder=oldSession?.folder,FileManager.default.fileExists(atPath:folder){self.manualWorkspace=true;self.workspaceURL=URL(fileURLWithPath:folder)}
                let recoveredPaths=Set(records.compactMap{$0.1.path})
                for path in oldSession?.paths ?? [] where !recoveredPaths.contains(path) && FileManager.default.fileExists(atPath:path) {self.openURL(URL(fileURLWithPath:path));self.documents.last?.pinned=oldSession?.pinnedPaths?.contains(path) == true}
                for (oldURL,r) in records {
                    let d=DocumentTab();d.url=r.path.map{URL(fileURLWithPath:$0)}
                    if let original=r.originalData {d.format=try? DocumentStorage.decode(original)}
                    d.loading=true;self.documents.append(d);self.configureEditor(d)
                    // Establish the disk version as savepoint before inserting the recovered text.
                    d.editor.text=d.format?.text ?? "";d.editor.send(2031,w:d.format?.lineEnding == "\r\n" ? 0:(d.format?.lineEnding == "\r" ? 1:2),l:0);d.editor.markSaved()
                    d.editor.send(2160,w:0,l:0) // Select all; replace without clearing undo history/savepoint.
                    d.editor.insertRecoveredText(r.text)
                    d.loading=false;d.language=LanguageRegistry.shared.language(for:d.url,text:String(r.text.prefix(200)));self.configureLanguage(d)
                    self.scheduleRecovery(d)
                    // Keep the old record until the new recovery record has been written.
                    let newRecordURL=self.recoveryURL.appendingPathComponent(d.id+".json")
                    self.recoveryQueue.asyncAfter(deadline:.now()+3) {if FileManager.default.fileExists(atPath:newRecordURL.path){try? FileManager.default.removeItem(at:oldURL)}}
                }
                self.coordinator?.restoreAdditionalWindows(Array((archive?.windows ?? []).dropFirst()))
                self.restoring=false
                if !records.isEmpty {if let blank=self.documents.first,blank.url==nil,!blank.isModified,blank.editor.text.isEmpty {self.documents.removeFirst()};self.selectDocument(self.documents.count-1)}
                self.updateAutomaticWorkspace();self.persistSession();self.offerFirstLaunchSetup()
            }
        }
    }
}
