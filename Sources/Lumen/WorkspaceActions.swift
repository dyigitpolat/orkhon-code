import Foundation

extension EditorWindowController {
    func updateAutomaticWorkspace() {
        if !manualWorkspace,remote == nil {
            let files=documents.filter{!$0.isWelcome && $0.remotePath == nil}.compactMap{$0.url}
            if let common=WorkspacePaths.commonParent(of:files),common != workspaceURL {
                workspaceURL=common;ensureTree();tree?.setRoot(common);terminal?.workingDirectory=common
            }
        }
        updateTreeOpenFiles()
    }
    func updateTreeOpenFiles() {
        updateFileMonitoring()
        tree?.setOpenFiles(documents.filter{!$0.isWelcome && $0.remotePath == nil}.compactMap{$0.url},activeURL:current?.url,workspaceMode:manualWorkspace)
    }
}
