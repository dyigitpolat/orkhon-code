import AppKit

/// A quiet, flat action rather than a filled button inside the source text.
private final class ConflictAction:NSButton {
    var foreground=NSColor.labelColor
    private var hovering=false
    override func updateTrackingAreas() {
        super.updateTrackingAreas();trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self))
    }
    override func mouseEntered(with event:NSEvent) {hovering=true;needsDisplay=true}
    override func mouseExited(with event:NSEvent) {hovering=false;needsDisplay=true}
    override func draw(_ dirtyRect:NSRect) {
        if hovering || isHighlighted {
            foreground.withAlphaComponent(isHighlighted ? 0.14:0.07).setFill()
            NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:2),xRadius:4,yRadius:4).fill()
        }
        contentTintColor=foreground;super.draw(dirtyRect)
    }
}

private final class ConflictToolbar:NSView {
    let badge=NSTextField(labelWithString:"Conflict")
    let buttons:[ConflictAction]
    init(theme:Theme,index:Int,target:AnyObject,action:Selector) {
        let titles=["Keep current","Use incoming","Keep both"]
        let symbols=["arrow.uturn.backward","arrow.down.left","square.stack"]
        buttons=titles.enumerated().map {value,title in
            let b=ConflictAction(title:title,target:target,action:action);b.tag=index*3+value
            b.isBordered=false;b.bezelStyle = .regularSquare;b.font = .systemFont(ofSize:11,weight:.medium)
            b.foreground=theme.foreground;b.imagePosition = .imageLeading
            b.image=NSImage(systemSymbolName:symbols[value],accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:10,weight:.medium))
            b.toolTip=title;b.setAccessibilityLabel(title);return b
        }
        super.init(frame:.zero);wantsLayer=true
        layer?.cornerRadius=6;layer?.backgroundColor=theme.panelColor.cgColor
        layer?.borderWidth=1;layer?.borderColor=NSColor.systemOrange.withAlphaComponent(theme.dark ? 0.38:0.3).cgColor
        badge.font = .systemFont(ofSize:10,weight:.semibold);badge.textColor=theme.dark ? NSColor(hex:0xE6BA87):NSColor(hex:0x96651F)
        addSubview(badge);buttons.forEach(addSubview)
        setAccessibilityLabel("Conflict actions")
    }
    required init?(coder:NSCoder) {fatalError("Use init(theme:index:target:action:)")}
    override func layout() {
        super.layout()
        let showBadge=bounds.width>=435,compact=bounds.width<370,iconsOnly=bounds.width<250
        badge.isHidden = !showBadge
        badge.frame=NSRect(x:12,y:floor((bounds.height-14)/2),width:56,height:14)
        let left:CGFloat=showBadge ? 76:5,width=max(0,(bounds.width-left-5)/3)
        for (index,button) in buttons.enumerated() {
            button.title=iconsOnly ? "":(compact ? ["Current","Incoming","Both"]:["Keep current","Use incoming","Keep both"])[index]
            button.imagePosition=iconsOnly ? .imageOnly:.imageLeading
            button.frame=NSRect(x:left+CGFloat(index)*width,y:3,width:width,height:max(0,bounds.height-6))
        }
    }
}

/// Only visible conflicts have native controls. The rest of this overlay passes
/// clicks and scrolling straight through to the live Scintilla document.
@MainActor
final class InlineExternalControls:NSView {
    let document:DocumentTab
    private weak var owner:EditorWindowController?
    private var rows:[Int:ConflictToolbar]=[:]
    private var revisionID:UUID?
    init(document:DocumentTab,owner:EditorWindowController) {
        self.document=document;self.owner=owner;super.init(frame:.zero)
        wantsLayer=true;layer?.masksToBounds=true
    }
    required init?(coder:NSCoder) {fatalError("Use init(document:owner:)")}
    func reload() {rows.values.forEach{$0.removeFromSuperview()};rows=[:];revisionID=document.externalChange?.id;needsLayout=true}
    override func hitTest(_ point:NSPoint)->NSView? {
        guard let view=super.hitTest(point),view !== self else{return nil}
        return view is NSButton ? view:nil
    }
    override func layout() {
        super.layout();guard let change=document.externalChange,let merge=change.merge,change.id==revisionID,let owner else{return}
        let editor=document.editor,anchors=document.externalAnchors
        let first=editor.send(2221,w:editor.send(2152,w:0,l:0),l:0)
        let last=editor.send(2221,w:editor.send(2152,w:0,l:0)+editor.send(2370,w:0,l:0)+2,l:0)
        var lower=0,upper=anchors.count
        while lower<upper {let middle=(lower+upper)/2;if anchors[middle].line<first {lower=middle+1} else {upper=middle}}
        var visible=Set<Int>()
        for anchor in anchors.dropFirst(lower) {
            if anchor.line>last && last>=0 {break}
            let rect=convert(editor.externalAnnotationFrame(atLine:anchor.line,row:anchor.row),from:editor).insetBy(dx:0,dy:2)
            guard rect.height>10,rect.intersects(bounds),merge.changes.indices.contains(anchor.index) else{continue}
            visible.insert(anchor.index)
            let row:ConflictToolbar
            if let existing=rows[anchor.index] {row=existing}
            else {
                row=ConflictToolbar(theme:owner.theme,index:anchor.index,target:self,action:#selector(choose(_:)))
                row.setAccessibilityLabel("Conflict at line \(anchor.line+1)")
                rows[anchor.index]=row;addSubview(row)
            }
            row.frame=NSRect(x:rect.minX,y:rect.minY,width:min(510,rect.width),height:rect.height)
            row.needsLayout=true
        }
        for index in Array(rows.keys) where !visible.contains(index) {rows.removeValue(forKey:index)?.removeFromSuperview()}
    }
    @objc private func choose(_ sender:NSButton) {
        guard let revisionID else{return}
        owner?.chooseExternalHunk(document,index:sender.tag/3,value:sender.tag%3,changeID:revisionID)
    }
}
