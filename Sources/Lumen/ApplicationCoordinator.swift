import AppKit

struct SessionArchive:Codable {let windows:[SessionRecord]}

/// Owns application lifetime. Each window owns its documents, panels and workspace.
@MainActor
final class ApplicationCoordinator:NSObject,NSApplicationDelegate {
    weak var menuOwner:EditorWindowController?
    private(set) var windows:[EditorWindowController]=[]
    private var pendingURLs:[URL]=[]
    private var launchStarted=false
    private var launchFinished=false
    private let sessionQueue=DispatchQueue(label:"app.orkhon.sessions",qos:.utility)
    private var restoringWindows=false
    private var lastSessionURL:URL?
    var active:EditorWindowController? {windows.first{$0.window === NSApp.mainWindow} ?? windows.last}

    func applicationDidFinishLaunching(_ notification:Notification) {
        guard !launchStarted else{return}
        launchStarted=true
        let controller=EditorWindowController();controller.coordinator=self;windows.append(controller)
        pendingURLs += ProcessInfo.processInfo.arguments.dropFirst().filter{!$0.hasPrefix("-") && FileManager.default.fileExists(atPath:$0)}.map{URL(fileURLWithPath:$0)}
        controller.applicationDidFinishLaunching(notification)
        // isRunning becomes true before didFinishLaunching. Only this explicit
        // boundary makes open/reopen events eligible to create another window.
        var seen=Set<URL>()
        controller.pendingURLs=pendingURLs.map{$0.standardizedFileURL.resolvingSymlinksInPath()}.filter{seen.insert($0).inserted}
        controller.suppressSessionRestore = !controller.pendingURLs.isEmpty
        pendingURLs=[];launchFinished=true
    }
    @discardableResult func newWindow()->EditorWindowController {
        let controller=EditorWindowController();controller.coordinator=self;windows.append(controller)
        controller.buildWindow();controller.newDocument(nil);controller.launched=true
        if windows.count>1,let previous=windows.dropLast().last?.window {
            controller.window.cascadeTopLeft(from: NSPoint(x:previous.frame.minX+24,y:previous.frame.maxY-24))
        }
        controller.bringToFront();return controller
    }
    func application(_ sender:NSApplication,open urls:[URL]) {
        guard !urls.isEmpty else{return}
        guard launchFinished else{pendingURLs+=urls;return}
        guard !windows.isEmpty else {
            let c=newWindow();urls.forEach{c.openURL($0)}
            return
        }
        for url in urls {
            let canonical=url.standardizedFileURL.resolvingSymlinksInPath()
            let owner=windows.first{$0.documents.contains{$0.url==canonical}} ?? active!
            owner.suppressSessionRestore=true
            owner.openURL(url);owner.bringToFront()
        }
        DispatchQueue.main.async {self.active?.bringToFront()}
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        guard launchFinished else{return true}
        if let active {active.bringToFront()} else {newWindow()};return true
    }
    func applicationDidBecomeActive(_ notification:Notification) {active?.applicationDidBecomeActive(notification)}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        for window in windows {if !window.canClose(terminating:true){return .terminateCancel}}
        persistSession();sessionQueue.sync {}
        windows.forEach{$0.finishClosing()};return .terminateNow
    }
    func removeWindow(_ controller:EditorWindowController) {
        windows.removeAll{$0 === controller};persistSession()
        // Keep File > New Window available when the last document window closes.
        if windows.isEmpty {controller.buildMenus()}
    }
    func releaseConnection(for controller:EditorWindowController) {
        if let connection=controller.remote,!windows.contains(where:{$0 !== controller && $0.remote === connection}) {connection.disconnect()}
        controller.remote=nil
    }
    func persistSession() {
        guard !restoringWindows,!windows.contains(where:{$0.restoring}) else{return}
        if let first=windows.first {lastSessionURL=first.sessionURL}
        guard let url=lastSessionURL else{return}
        let archive=SessionArchive(windows:windows.map(\.sessionRecord))
        sessionQueue.async {
            do {try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(archive).write(to:url,options:.atomic)}
            catch {NSLog("Session write failed: %@",error.localizedDescription)}
        }
    }
    func restoreAdditionalWindows(_ records:[SessionRecord]) {
        restoringWindows=true;defer{restoringWindows=false}
        for record in records {
            let c=newWindow();c.restoring=true
            if let folder=record.folder,FileManager.default.fileExists(atPath:folder) {c.setFolder(URL(fileURLWithPath:folder))}
            for path in record.paths where FileManager.default.fileExists(atPath:path) {c.openURL(URL(fileURLWithPath:path));c.documents.last?.pinned=record.pinnedPaths?.contains(path)==true}
            c.restoring=false
        }
    }
    @objc func createWindow(_ sender:Any?) {newWindow()}
}

extension EditorWindowController {
    @objc func newWindow(_ sender:Any?) {coordinator?.newWindow()}
    @objc func closeEditorWindow(_ sender:Any?) {window.performClose(sender)}
    @objc func openInNewWindow(_ sender:Any?) {
        let panel=NSOpenPanel();panel.allowsMultipleSelection=true;panel.prompt="Open in New Window"
        panel.beginSheetModal(for:window) { [weak self] result in
            guard result == .OK,let c=self?.coordinator?.newWindow() else{return}
            panel.urls.forEach{c.openURL($0)}
        }
    }
    @objc func moveCurrentToNewWindow(_ sender:Any?) {if let d=current {moveToNewWindow(d)}}
    @objc func moveMenuTabToNewWindow(_ sender:NSMenuItem) {if let d=sender.representedObject as? DocumentTab {moveToNewWindow(d)}}
    func moveToNewWindow(_ document:DocumentTab) {
        guard !document.loading,documents.contains(where:{$0 === document}),let destination=coordinator?.newWindow() else{return}
        detachForTransfer(document)
        destination.documents.forEach{$0.editor.removeFromSuperview()}
        destination.documents=[document];destination.selected = -1
        if document.remotePath != nil {destination.remote=remote;destination.ensureRemoteTree();destination.remoteTree?.setRoot(remote?.directory ?? "/")}
        destination.configureEditor(document);destination.selectDocument(0);destination.scheduleRecovery(document)
        updateAutomaticWorkspace();persistSession();destination.bringToFront()
    }
}
