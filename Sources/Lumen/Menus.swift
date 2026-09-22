import AppKit
extension EditorWindowController {
    func refreshRecents() {
        recentFilesMenu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {let i=NSMenuItem(title:url.lastPathComponent,action:#selector(openRecent(_:)),keyEquivalent:"");i.representedObject=url;i.toolTip=url.path;i.target=self;recentFilesMenu.addItem(i)}
        if recentFilesMenu.items.isEmpty {let i=NSMenuItem(title:"No Recent Files",action:nil,keyEquivalent:"");recentFilesMenu.addItem(i)}
        recentFilesMenu.addItem(.separator());let clear=NSMenuItem(title:"Clear Menu",action:#selector(clearRecents(_:)),keyEquivalent:"");clear.target=self;recentFilesMenu.addItem(clear)
    }
    @objc func openRecent(_ sender:NSMenuItem) {if let url=sender.representedObject as? URL {openURL(url)}}
    @objc func clearRecents(_ sender:Any?) {NSDocumentController.shared.clearRecentDocuments(sender);refreshRecents()}
    func buildMenus() {
        if coordinator?.menuOwner === self {return};coordinator?.menuOwner=self
        recentFilesMenu=NSMenu(title:"Open Recent")
        let main=NSMenu();NSApp.mainMenu=main
        func section(_ name:String)->NSMenu {let item=NSMenuItem(title:name,action:nil,keyEquivalent:"");let menu=NSMenu(title:name);item.submenu=menu;main.addItem(item);return menu}
        func item(_ menu:NSMenu,_ title:String,_ action:Selector,_ key:String="",_ mods:NSEvent.ModifierFlags = .command,_ tag:Int=0,_ target:AnyObject?=nil) {
            let i=NSMenuItem(title:title,action:action,keyEquivalent:key);i.keyEquivalentModifierMask=mods;i.target=target ?? self;i.tag=tag;menu.addItem(i)
        }
        let app=section("Orkhon Editor")
        item(app,"About Orkhon Editor",#selector(about(_:)));item(app,"File Defaults…",#selector(showFileSetup(_:)));app.addItem(.separator())
        let services=NSMenuItem(title:"Services",action:nil,keyEquivalent:"");services.submenu=NSMenu();app.addItem(services);NSApp.servicesMenu=services.submenu
        app.addItem(.separator());item(app,"Hide Orkhon Editor",#selector(NSApplication.hide(_:)),"h",.command,0,NSApp)
        item(app,"Hide Others",#selector(NSApplication.hideOtherApplications(_:)),"h",[.command,.option],0,NSApp)
        item(app,"Show All",#selector(NSApplication.unhideAllApplications(_:)),"",.command,0,NSApp)
        app.addItem(.separator());item(app,"Quit Orkhon Editor",#selector(NSApplication.terminate(_:)),"q",.command,0,NSApp)
        let file=section("File")
        item(file,"Connect over SSH…",#selector(connectRemote(_:)));item(file,"Disconnect SSH",#selector(disconnectRemote(_:)));file.addItem(.separator())
        item(file,"New Window",#selector(ApplicationCoordinator.createWindow(_:)),"n",[.command,.shift],0,coordinator);item(file,"Open in New Window…",#selector(openInNewWindow(_:)),"o",[.command,.option]);item(file,"New Tab",#selector(newDocument(_:)),"n");item(file,"Open…",#selector(openFile(_:)),"o");item(file,"Open Folder…",#selector(openFolder(_:)),"o",[.command,.shift])
        let encoded=NSMenuItem(title:"Open with Encoding",action:nil,keyEquivalent:"");let encodingMenu=NSMenu();encoded.submenu=encodingMenu;file.addItem(encoded)
        for (index,name) in ["Western (Windows 1252)","Western (ISO Latin 1)","Japanese (Shift JIS)","Mac Roman"].enumerated() {item(encodingMenu,name+"…",#selector(openWithEncoding(_:)),"",.command,index)}
        let recent=NSMenuItem(title:"Open Recent",action:nil,keyEquivalent:"");let recentMenu=recentFilesMenu;recent.submenu=recentMenu;file.addItem(recent);refreshRecents()

        file.addItem(.separator());item(file,"Close Window",#selector(closeEditorWindow(_:)),"w",[.command,.shift]);item(file,"Close Tab",#selector(closeCurrent(_:)),"w");item(file,"Save",#selector(save(_:)),"s");item(file,"Save As…",#selector(saveAs(_:)),"s",[.command,.shift]);item(file,"Save All",#selector(saveAll(_:)),"s",[.command,.option]);item(file,"Reload from Disk…",#selector(revert(_:)))
        file.addItem(.separator());item(file,"Print…",#selector(printDocument(_:)),"p",[.command,.option])
        let edit=section("Edit")
        for (title,sel,key,mods) in [("Undo","undo:","z",NSEvent.ModifierFlags.command),("Redo","redo:","z",[.command,.shift]),("Cut","cut:","x",.command),("Copy","copy:","c",.command),("Paste","paste:","v",.command),("Select All","selectAll:","a",.command)] {
            let i=NSMenuItem(title:title,action:NSSelectorFromString(sel),keyEquivalent:key);i.keyEquivalentModifierMask=mods;edit.addItem(i)
        }
        edit.addItem(.separator());item(edit,"Find and Replace…",#selector(showFind(_:)),"f");item(edit,"Find and Replace",#selector(showFind(_:)),"f",.control);item(edit,"Find Next",#selector(findNext(_:)),"g");item(edit,"Find Previous",#selector(findPrevious(_:)),"g",[.command,.shift]);item(edit,"Go to Line…",#selector(goToLine(_:)),"l")
        edit.addItem(.separator());item(edit,"Toggle Line Comment",#selector(toggleComment(_:)),"/");item(edit,"Duplicate Selection or Line",#selector(editorCommand(_:)),"d",[.command,.shift],2469);item(edit,"Select Next Occurrence",#selector(editorCommand(_:)),"d",.command,2688)
        item(edit,"Move Line Up",#selector(editorCommand(_:)),String(UnicodeScalar(NSUpArrowFunctionKey)!),[.option],2620);item(edit,"Move Line Down",#selector(editorCommand(_:)),String(UnicodeScalar(NSDownArrowFunctionKey)!),[.option],2621)
        item(edit,"Indent",#selector(editorCommand(_:)),"]",.command,2327);item(edit,"Outdent",#selector(editorCommand(_:)),"[",.command,2328)
        let view=section("View")
        item(view,"Side-by-Side Preview",#selector(splitPreview(_:)));item(view,"Toggle Preview",#selector(toggleMarkdown(_:)),"m",[.command,.shift]);item(view,"Command Palette…",#selector(showCommandPalette(_:)),"p",[.command,.shift]);item(view,"Quick Open…",#selector(showQuickOpen(_:)),"p",.command)
        item(view,"Toggle Files",#selector(toggleSidebar(_:)),"b");item(view,"Toggle Terminal",#selector(toggleTerminal(_:)),"`",.control);item(view,"Expand Terminal",#selector(expandTerminal(_:)),"`",[.control,.shift]);view.addItem(.separator())
        item(view,"Word Wrap",#selector(toggleWrap(_:)),"z",.option);item(view,"Show Whitespace",#selector(toggleWhitespace(_:)))
        item(view,"Increase Font Size",#selector(zoomIn(_:)),"+");item(view,"Decrease Font Size",#selector(zoomOut(_:)),"-");item(view,"Reset Font Size",#selector(zoomReset(_:)),"0")
        let themes=NSMenuItem(title:"Theme",action:nil,keyEquivalent:"");let themeMenu=NSMenu();themes.submenu=themeMenu;view.addItem(themes)
        for (index,t) in Theme.all.enumerated() {item(themeMenu,t.name,#selector(selectThemeMenu(_:)),"",.command,index)}
        let indent=NSMenuItem(title:"Indentation",action:nil,keyEquivalent:"");let indentMenu=NSMenu();indent.submenu=indentMenu;view.addItem(indent)
        for n in [2,4,8] {item(indentMenu,"\(n) columns",#selector(setIndent(_:)),"",.command,n)};item(indentMenu,"Use Tab Characters",#selector(toggleTabs(_:)))
        let win=section("Window");NSApp.windowsMenu=win
        item(win,"Minimize",#selector(NSWindow.performMiniaturize(_:)),"m",.command,0,nil);win.items.last?.target=nil
        item(win,"Zoom",#selector(NSWindow.performZoom(_:)));win.items.last?.target=nil
        item(win,"Move Tab to New Window",#selector(moveCurrentToNewWindow(_:)));item(win,"Next Tab",#selector(nextTab(_:)),"]",[.command,.shift]);item(win,"Previous Tab",#selector(previousTab(_:)),"[",[.command,.shift])
        item(win,"Enter Full Screen",#selector(NSWindow.toggleFullScreen(_:)),"f",[.command,.control]);win.items.last?.target=nil
        let help=section("Help");NSApp.helpMenu=help;item(help,"Orkhon Editor Guide",#selector(self.help(_:)))
    }
}
extension EditorWindowController:NSMenuItemValidation {
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        switch item.action {
        case #selector(toggleMarkdown(_:)):return current?.previewKind != nil
        case #selector(splitPreview(_:)):return current?.previewKind != nil && !editorIsSplit
        case #selector(toggleWrap(_:)):item.state=wrap ? .on:.off
        case #selector(toggleWhitespace(_:)):item.state=whitespace ? .on:.off
        case #selector(toggleTabs(_:)):item.state=current?.editor.useTabs == true ? .on:.off
        case #selector(selectThemeMenu(_:)):item.state=Theme.all[item.tag].name==theme.name ? .on:.off
        case #selector(toggleSidebar(_:)):item.state=treeItem?.isCollapsed == false ? .on:.off
        case #selector(toggleTerminal(_:)):item.state=terminalItem?.isCollapsed == false ? .on:.off
        case #selector(moveCurrentToNewWindow(_:)):return current?.loading == false
        case #selector(save(_:)),#selector(saveAs(_:)):return current?.loading == false
        case #selector(toggleComment(_:)):return lineCommentPrefix != nil
        case #selector(revert(_:)):return current?.url != nil && current?.loading == false
        default:break
        }
        return true
    }
}
