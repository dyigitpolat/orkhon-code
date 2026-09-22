import AppKit

/// Equal-width script spans keep the compact titlebar mark balanced. The Latin
/// face is SF Mono; macOS supplies its native Old Turkic face for the second span.
final class BrandMark:NSView {
    var textColor=NSColor.labelColor {didSet{needsDisplay=true}}
    private let latin=NSFont.monospacedSystemFont(ofSize:11,weight:.bold)
    private let turkic=NSFont(name:"NotoSansOldTurkic-Regular",size:11) ?? NSFont.systemFont(ofSize:11)
    override init(frame:NSRect) {
        super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.staticText)
        setAccessibilityLabel("ORKHON ⸱ 𐰏𐱃𐱁‎𐰋𐰃𐱅‎")
    }
    required init?(coder:NSCoder) {fatalError("Use init(frame:)")}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func draw(_ dirtyRect:NSRect) {
        drawSpan("ORKHON",font:latin,x:0,width:48)
        // U+2E31 word-separator middle dot. Draw the round mark explicitly;
        // the compact system-font fallback can otherwise resemble a dash.
        textColor.setFill();NSBezierPath(ovalIn:NSRect(x:56.1,y:bounds.midY-0.9,width:1.8,height:1.8)).fill()
        drawSpan("𐰏𐱃𐱁‎𐰋𐰃𐱅‎",font:turkic,x:66,width:48)
    }
    private func drawSpan(_ value:String,font:NSFont,x:CGFloat,width:CGFloat) {
        let string=NSMutableAttributedString(string:value,attributes:[.font:font,.foregroundColor:textColor])
        let range=NSRange(location:0,length:string.length)
        let natural=string.size().width
        if value.count>1 {
            // Measure tracking with the shaping engine so bidi marks contribute
            // correctly. Never stretch or squeeze the historic glyph shapes.
            string.addAttribute(.kern,value:1,range:range)
            let response=string.size().width-natural
            if response>0 {string.addAttribute(.kern,value:max(0,(width-natural)/response),range:range)}
        }
        let size=string.size()
        string.draw(at:NSPoint(x:x+(width-size.width)/2,y:(bounds.height-size.height)/2))
    }
}
