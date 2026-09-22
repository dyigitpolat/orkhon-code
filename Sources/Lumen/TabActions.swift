import AppKit

final class DocumentTabButton:NSButton,NSDraggingSource {
    var documentID:String?
    override func mouseDown(with event:NSEvent) {
        guard let documentID,!event.modifierFlags.contains(.control),let window else{super.mouseDown(with:event);return}
        let start=event.locationInWindow
        while let next=window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp {performClick(nil);return}
            if hypot(next.locationInWindow.x-start.x,next.locationInWindow.y-start.y)>5 {
                let item=NSPasteboardItem();item.setString(documentID,forType:documentTabPasteboard)
                let drag=NSDraggingItem(pasteboardWriter:item)
                let image=NSImage(size:bounds.size,flipped:false) { rect in NSColor.windowBackgroundColor.setFill();NSBezierPath(roundedRect:rect,xRadius:6,yRadius:6).fill();self.title.draw(in:rect.insetBy(dx:8,dy:6),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.labelColor]);return true }
                drag.setDraggingFrame(bounds,contents:image);beginDraggingSession(with:[drag],event:next,source:self);return
            }
        }
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation {.move}
    var contextMenu:(()->NSMenu)?
    override func menu(for event:NSEvent)->NSMenu? {contextMenu?()}
}

extension EditorWindowController {
    func bringToFront() {
        if window.isMiniaturized {window.deminiaturize(nil)}
        NSApp.activate(ignoringOtherApps:true)
        window.makeKeyAndOrderFront(nil)
    }
    func tabMenu(for document:DocumentTab)->NSMenu {
        let menu=NSMenu()
        for (title,action) in [(document.pinned ? "Unpin Tab":"Pin Tab",#selector(pinTab(_:))),("Split to the Left",#selector(splitTabLeft(_:))),("Split to the Right",#selector(splitTabRight(_:))),("Move to New Window",#selector(moveMenuTabToNewWindow(_:))),("Close Tab",#selector(closeMenuTab(_:))),("Close Others",#selector(closeOtherTabs(_:))),("Close to the Right",#selector(closeTabsToRight(_:)))] {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;item.representedObject=document;menu.addItem(item)
        }
        return menu
    }
    @objc func pinTab(_ sender:NSMenuItem) {
        guard let d=sender.representedObject as? DocumentTab,let index=documents.firstIndex(where:{$0===d}) else{return}
        let active=current;documents.remove(at:index);d.pinned.toggle()
        documents.insert(d,at:documents.prefix(while:{$0.pinned}).count)
        if let active,let newIndex=documents.firstIndex(where:{$0===active}) {selected=newIndex}
        rebuildTabs();revealSelectedTab();persistSession()
    }
    @objc func closeMenuTab(_ sender:NSMenuItem) {if let d=sender.representedObject as? DocumentTab,confirmClose(d){removeDocument(d)}}
    @objc func closeOtherTabs(_ sender:NSMenuItem) {
        guard let d=sender.representedObject as? DocumentTab else{return}
        closeDocuments(documents.filter{$0 !== d && !$0.pinned})
    }
    @objc func closeTabsToRight(_ sender:NSMenuItem) {
        guard let d=sender.representedObject as? DocumentTab,let index=documents.firstIndex(where:{$0===d}) else{return}
        closeDocuments(Array(documents.dropFirst(index+1)).filter{!$0.pinned})
    }
    func closeDocuments(_ targets:[DocumentTab]) {
        for d in targets {guard confirmClose(d) else{return};removeDocument(d)}
    }
    func revealSelectedTab() {
        tabStack.layoutSubtreeIfNeeded()
        guard tabStack.arrangedSubviews.indices.contains(selected) else{return}
        tabStack.scrollToVisible(tabStack.arrangedSubviews[selected].frame.insetBy(dx:-6,dy:0));updateTabOverflow()
    }
    func updateTabOverflow() {
        let visible=tabScroll.documentVisibleRect
        tabBack.isEnabled=visible.minX>1
        tabForward.isEnabled=visible.maxX<tabStack.bounds.width-1
        allTabs.title="\(documents.count)"
        allTabs.toolTip="\(documents.count) open tabs"
    }
    @objc func scrollTabsBack(_ sender:Any?) {scrollTabs(-1)}
    @objc func scrollTabsForward(_ sender:Any?) {scrollTabs(1)}
    func scrollTabs(_ direction:CGFloat) {
        let clip=tabScroll.contentView
        let x=max(0,min(tabStack.bounds.width-clip.bounds.width,clip.bounds.minX+direction*max(172,clip.bounds.width*0.7)))
        clip.scroll(to:NSPoint(x:x,y:0));tabScroll.reflectScrolledClipView(clip);updateTabOverflow()
    }
    @objc func listTabs(_ sender:NSButton) {
        let menu=NSMenu()
        for (index,d) in documents.enumerated() {
            let item=NSMenuItem(title:(d.pinned ? "⌖ ":"")+d.title,action:#selector(selectTabMenu(_:)),keyEquivalent:"");item.tag=index;item.target=self;item.state=index==selected ? .on:.off;menu.addItem(item)
        }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.minY),in:sender)
    }
    @objc func selectTabMenu(_ sender:NSMenuItem) {selectDocument(sender.tag)}
}
