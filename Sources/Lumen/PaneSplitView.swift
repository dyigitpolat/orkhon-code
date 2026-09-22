import AppKit

/// Two retained panes with an explicit ratio. Hiding a pane does not erase its
/// previous size, unlike proportional layout based on a collapsed zero-width view.
final class PaneSplitView:NSView {
    private(set) var arrangedSubviews:[NSView]=[]
    private lazy var divider=PaneDivider(owner:self)
    let dividerThickness:CGFloat=1
    var ratio:CGFloat=0.5 {didSet{ratio=min(0.82,max(0.18,ratio));needsLayout=true}}
    override init(frame:NSRect) {super.init(frame:frame);autoresizesSubviews=false;setAccessibilityRole(.splitGroup)}
    required init?(coder:NSCoder) {fatalError("Use init(frame:)")}
    func addArrangedSubview(_ view:NSView) {precondition(arrangedSubviews.count<2);arrangedSubviews.append(view);addSubview(view);addSubview(divider,positioned:.above,relativeTo:nil);needsLayout=true}
    func setPosition(_ position:CGFloat,ofDividerAt index:Int) {guard bounds.width>1 else{return};ratio=position/(bounds.width-1);layoutSubtreeIfNeeded()}
    func adjustSubviews() {needsLayout=true;layoutSubtreeIfNeeded()}
    override func layout() {
        super.layout();guard arrangedSubviews.count==2 else{return}
        let first=arrangedSubviews[0],second=arrangedSubviews[1]
        if first.isHidden || second.isHidden {
            divider.isHidden=true
            // Retain hidden geometry: shrinking Scintilla below its gutter width
            // creates conflicting native scroll-view constraints during transitions.
            for view in arrangedSubviews where !view.isHidden {view.frame=bounds;view.needsLayout=true}
        } else {
            divider.isHidden=false
            let width=max(0,bounds.width-dividerThickness),left=width*ratio
            first.frame=NSRect(x:0,y:0,width:left,height:bounds.height)
            second.frame=NSRect(x:left+dividerThickness,y:0,width:width-left,height:bounds.height)
            divider.frame=NSRect(x:left-4,y:0,width:9,height:bounds.height)
            first.needsLayout=true;second.needsLayout=true
        }
    }
}

private final class PaneDivider:NSView {
    weak var owner:PaneSplitView?
    init(owner:PaneSplitView) {self.owner=owner;super.init(frame:.zero);setAccessibilityRole(.splitter);setAccessibilityLabel("Resize editor panes")}
    required init?(coder:NSCoder) {fatalError("Use init(owner:)")}
    override func draw(_ dirtyRect:NSRect) {NSColor.separatorColor.setFill();NSRect(x:4,y:0,width:1,height:bounds.height).fill()}
    override func resetCursorRects() {addCursorRect(bounds,cursor:.resizeLeftRight)}
    override func mouseDown(with event:NSEvent) {
        guard let owner,let window else{return}
        while let next=window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp {break}
            owner.setPosition(owner.convert(next.locationInWindow,from:nil).x,ofDividerAt:0)
        }
    }
    override func accessibilityPerformIncrement()->Bool {guard let owner else{return false};owner.ratio+=0.05;return true}
    override func accessibilityPerformDecrement()->Bool {guard let owner else{return false};owner.ratio-=0.05;return true}
}
