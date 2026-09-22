import Foundation
extension EditorWindowController {
    func reconcileMovedFiles(from old:URL,to new:URL) {
        for d in documents {
            guard let url=d.url else{continue}
            if url == old {d.url=new}
            else if url.path.hasPrefix(old.path+"/") {d.url=new.appendingPathComponent(String(url.path.dropFirst(old.path.count+1)))}
            else {continue}
            if !d.languageOverride {d.language=LanguageRegistry.shared.language(for:d.url,text:String(d.editor.text.prefix(200)));configureLanguage(d)}
            if d.isModified {scheduleRecovery(d)}
        }
        rebuildTabs();updateStatus();persistSession()
    }
    func reconcileTrashedFiles(_ url:URL) {
        for d in documents {
            guard let path=d.url?.path,path == url.path || path.hasPrefix(url.path+"/") else{continue}
            let text=d.editor.text;d.url=nil;d.format=nil
            if !d.isModified && !text.isEmpty {d.loading=true;d.editor.text="";d.editor.insertRecoveredText(text);d.loading=false}
            scheduleRecovery(d)
        }
        rebuildTabs();updateStatus();persistSession()
    }
}
