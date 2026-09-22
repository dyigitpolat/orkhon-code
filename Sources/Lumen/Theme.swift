import AppKit

extension NSColor {
    convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
}
struct Theme {
    let name: String
    let dark: Bool
    let bg, panel, fg, muted, accent, selection, line, keyword, string, number, comment, type: UInt32
    var background: NSColor { NSColor(hex: bg) }
    var panelColor: NSColor { NSColor(hex: panel) }
    var foreground: NSColor { NSColor(hex: fg) }
    var accentColor: NSColor { NSColor(hex: accent) }
    var palette: [String:NSColor] {
        ["background":background,"foreground":foreground,"muted":NSColor(hex:muted),"selection":NSColor(hex:selection),"line":NSColor(hex:line),"accent":accentColor,"keyword":NSColor(hex:keyword),"string":NSColor(hex:string),"number":NSColor(hex:number),"comment":NSColor(hex:comment),"type":NSColor(hex:type),"operator":NSColor(hex:accent)]
    }
    static let all: [Theme] = [
        Theme(name:"Obsidian",dark:true,bg:0x15181E,panel:0x1C2028,fg:0xD8DEE9,muted:0x7D8799,accent:0x83C9BE,selection:0x35465C,line:0x1C232D,keyword:0xC7A6F5,string:0xAAD7A0,number:0xE6BA87,comment:0x7C889B,type:0x88BFDF),
        Theme(name:"Daylight",dark:false,bg:0xFAFBFC,panel:0xEEF1F4,fg:0x293344,muted:0x667385,accent:0x227E76,selection:0xC9DFEF,line:0xF0F3F7,keyword:0x8A42B5,string:0x327D40,number:0xA45920,comment:0x70816D,type:0x216CA3),
        Theme(name:"Dusk",dark:true,bg:0x22212C,panel:0x2B2938,fg:0xE3DFEC,muted:0x9992AE,accent:0xC6A0F6,selection:0x49415E,line:0x2D293B,keyword:0xEBA0C3,string:0xA6D4B0,number:0xF1BC98,comment:0x8F87A0,type:0x91C8DD),
        Theme(name:"Paper",dark:false,bg:0xF7F3E9,panel:0xEBE5D8,fg:0x403F37,muted:0x7A796C,accent:0x66815C,selection:0xD9DEC5,line:0xEEEBDF,keyword:0x975D84,string:0x5D7746,number:0xA26936,comment:0x8B8C78,type:0x4F7881)
    ]
}
class Surface: NSView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
    func color(_ c: NSColor) { wantsLayer=true; layer?.backgroundColor=c.cgColor }
}
func iconButton(_ symbol:String,_ help:String,target:AnyObject?,action:Selector) -> NSButton {
    let b=NSButton(image:NSImage(systemSymbolName:symbol,accessibilityDescription:help) ?? NSImage(),target:target,action:action)
    b.bezelStyle = .texturedRounded; b.isBordered=false; b.toolTip=help; b.setAccessibilityLabel(help)
    b.frame.size=NSSize(width:32,height:30)
    return b
}

/// A compact, keyboard-accessible control shared by the editor's utility bars.
final class PillButton: NSButton {
    var accent=NSColor.controlAccentColor
    var foreground=NSColor.labelColor
    override var state:NSControl.StateValue { didSet { needsDisplay=true } }
    override func draw(_ dirtyRect:NSRect) {
        let selected=state == .on
        (selected ? accent.withAlphaComponent(0.22) : foreground.withAlphaComponent(0.07)).setFill()
        NSBezierPath(roundedRect:bounds, xRadius:6,yRadius:6).fill()
        isBordered=false
        contentTintColor=selected ? accent : foreground
        super.draw(dirtyRect)
    }
}

/// A shared vertical inset for the placeholder, text drawing and field editor.
final class CenteredTextCell:NSTextFieldCell {
    override func drawingRect(forBounds rect:NSRect)->NSRect {
        var bounds=super.drawingRect(forBounds:rect)
        let height=min(bounds.height,ceil((font?.ascender ?? 13)-(font?.descender ?? -3))+2)
        bounds.origin.y += floor((bounds.height-height)/2)
        bounds.size.height=height
        return bounds
    }
    override func edit(withFrame rect:NSRect,in controlView:NSView,editor:NSText,delegate:Any?,event:NSEvent?) {super.edit(withFrame:drawingRect(forBounds:rect),in:controlView,editor:editor,delegate:delegate,event:event)}
    override func select(withFrame rect:NSRect,in controlView:NSView,editor:NSText,delegate:Any?,start:Int,length:Int) {super.select(withFrame:drawingRect(forBounds:rect),in:controlView,editor:editor,delegate:delegate,start:start,length:length)}
}
final class CenteredTextField:NSTextField {
    override init(frame:NSRect) {super.init(frame:frame);configureCell()}
    required init?(coder:NSCoder) {super.init(coder:coder);configureCell()}
    private func configureCell() {cell=CenteredTextCell(textCell:"");isEditable=true;isSelectable=true;cell?.usesSingleLineMode=true}
}

final class TitleBarSurface:Surface {
    override var mouseDownCanMoveWindow:Bool {true}
    override func mouseDown(with event:NSEvent) {
        if event.clickCount==2 {
            switch UserDefaults.standard.string(forKey:"AppleActionOnDoubleClick")?.lowercased() {
            case "minimize":window?.performMiniaturize(nil)
            case "none":break
            default:window?.performZoom(nil)
            }
        } else {super.mouseDown(with:event)}
    }
}
