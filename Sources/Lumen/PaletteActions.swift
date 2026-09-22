import AppKit
extension EditorWindowController {
    @objc func showCommandPalette(_ sender:Any?) {
        let commands:[(String,String,String)] = [
            ("New Tab","⌘N","new"),("Open File…","⌘O","open"),("Open Folder…","⇧⌘O","folder"),("Save","⌘S","save"),("Save As…","⇧⌘S","saveas"),("Save All","⌥⌘S","saveall"),("Find in Document","⌘F","find"),("Find and Replace","⌥⌘F","replace"),("Go to Line","⌘L","goto"),("Toggle Files","⌘B","files"),("Toggle Terminal","⌃`","terminal"),("Expand Terminal","⇧⌃`","expand"),("Toggle Word Wrap","⌥Z","wrap"),("Toggle Whitespace","","whitespace"),("Toggle Line Comment","⌘/","comment"),("Increase Font Size","⌘+","larger"),("Decrease Font Size","⌘−","smaller"),("Quick Open","⌘P","quick"),("Reload from Disk","","reload")]
        var items=commands.map {PaletteItem(title:$0.0,subtitle:"Command",shortcut:$0.1,identifier:$0.2)}
        items+=Theme.all.enumerated().map {PaletteItem(title:"Theme: \($0.element.name)",subtitle:$0.element.dark ? "Dark appearance":"Light appearance",shortcut:"",identifier:"theme:\($0.offset)")}
        paletteWindow=CommandPalette(parent:window,title:"Command Palette",placeholder:"What would you like to do?",items:items) { [weak self] item in self?.runPaletteCommand(item.identifier) }
        paletteWindow?.present()
    }
    func runPaletteCommand(_ id:String) {
        if id.hasPrefix("theme:"),let n=Int(id.dropFirst(6)) {chooseTheme(n);return}
        switch id {
        case "new":newDocument(nil);case "open":openFile(nil);case "folder":openFolder(nil);case "save":save(nil);case "saveas":saveAs(nil);case "saveall":saveAll(nil)
        case "find":showFind(nil);case "replace":showReplace(nil);case "goto":goToLine(nil);case "files":toggleSidebar(nil);case "terminal":toggleTerminal(nil);case "expand":expandTerminal(nil)
        case "wrap":toggleWrap(nil);case "whitespace":toggleWhitespace(nil);case "comment":toggleComment(nil);case "larger":zoomIn(nil);case "smaller":zoomOut(nil);case "quick":showQuickOpen(nil);case "reload":revert(nil)
        default:break
        }
    }
    @objc func showQuickOpen(_ sender:Any?) {
        let open=documents.compactMap(\.url),recent=NSDocumentController.shared.recentDocumentURLs,folder=workspaceURL
        status.stringValue="Finding files…"
        ioQueue.async { [weak self] in
            var files=Set(open+recent),capped=false
            if let folder,let enumerator=FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey],options:[.skipsPackageDescendants,.skipsHiddenFiles]) {
                let skip:Set<String>=["node_modules","target","build","dist","vendor","Pods","DerivedData"]
                for case let url as URL in enumerator {
                    guard let attrs=try? url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey]) else{continue}
                    if attrs.isSymbolicLink == true {enumerator.skipDescendants();continue}
                    if attrs.isDirectory == true {if skip.contains(url.lastPathComponent)||enumerator.level>15{enumerator.skipDescendants()};continue}
                    if attrs.isRegularFile == true {files.insert(url)}
                    if files.count>=20000 {capped=true;break}
                }
            }
            let items=files.sorted{$0.path.localizedStandardCompare($1.path) == .orderedAscending}.map{url in PaletteItem(title:url.lastPathComponent,subtitle:folder.map{url.path.replacingOccurrences(of:$0.path+"/",with:"")} ?? url.deletingLastPathComponent().path,shortcut:open.contains(url) ? "Open":"",identifier:url.path)}
            DispatchQueue.main.async {
                guard let self else{return};self.updateStatus()
                self.paletteWindow=CommandPalette(parent:self.window,title:capped ? "Quick Open · first 20,000 files":"Quick Open",placeholder:folder == nil ? "Search open and recent files…":"Search workspace files…",items:items) { [weak self] item in self?.openURL(URL(fileURLWithPath:item.identifier)) }
                self.paletteWindow?.present()
            }
        }
    }
}
