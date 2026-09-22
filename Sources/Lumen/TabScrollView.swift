import AppKit

/// A permanently reserved four-point track. It never covers the tab labels.
final class TabScrollView:NSScrollView {
    private lazy var rail=TabScrollRail(owner:self)
    var accent=NSColor.controlAccentColor {didSet{rail.needsDisplay=true}}
    var onScroll:(()->Void)?
    override init(frame:NSRect) {
        super.init(frame:frame);hasHorizontalScroller=false;hasVerticalScroller=false;drawsBackground=false
        addSubview(rail);contentView.postsBoundsChangedNotifications=true
        NotificationCenter.default.addObserver(self,selector:#selector(scrolled),name:NSView.boundsDidChangeNotification,object:contentView)
    }
    required init?(coder:NSCoder) {fatalError("Use init(frame:)")}
    deinit {NotificationCenter.default.removeObserver(self)}
    override func tile() {
        super.tile()
        var area=bounds
        if isFlipped {area.size.height=max(0,area.height-5);rail.frame=NSRect(x:0,y:area.maxY,width:area.width,height:5)}
        else {area.origin.y+=5;area.size.height=max(0,area.height-5);rail.frame=NSRect(x:0,y:0,width:area.width,height:5)}
        contentView.frame=area;rail.needsDisplay=true
    }
    @objc private func scrolled() {rail.needsDisplay=true;onScroll?()}
    override func scrollWheel(with event:NSEvent) {
        let delta=abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY) ? event.scrollingDeltaX:event.scrollingDeltaY
        scroll(to:contentView.bounds.minX-delta*(event.hasPreciseScrollingDeltas ? 1:12))
    }
    func scroll(to x:CGFloat) {
        let limit=max(0,(documentView?.bounds.width ?? 0)-contentView.bounds.width)
        contentView.scroll(to:NSPoint(x:min(limit,max(0,x)),y:0));reflectScrolledClipView(contentView);scrolled()
    }
    fileprivate var thumb:NSRect {
        let total=documentView?.bounds.width ?? 0,visible=contentView.bounds.width
        guard total>visible,total>0 else{return .zero}
        let width=max(24,rail.bounds.width*visible/total),travel=max(0,rail.bounds.width-width)
        return NSRect(x:travel*contentView.bounds.minX/max(1,total-visible),y:1,width:width,height:3)
    }
}

private final class TabScrollRail:NSView {
    weak var owner:TabScrollView?
    private var dragOffset:CGFloat=0
    init(owner:TabScrollView) {self.owner=owner;super.init(frame:.zero);setAccessibilityLabel("Tab scroll position");setAccessibilityRole(.scrollBar)}
    required init?(coder:NSCoder) {fatalError("Use init(owner:)")}
    override func draw(_ dirtyRect:NSRect) {
        guard let owner,!owner.thumb.isEmpty else{return}
        owner.accent.withAlphaComponent(0.12).setFill();NSBezierPath(roundedRect:NSRect(x:0,y:1,width:bounds.width,height:3),xRadius:1.5,yRadius:1.5).fill()
        owner.accent.withAlphaComponent(0.65).setFill();NSBezierPath(roundedRect:owner.thumb,xRadius:1.5,yRadius:1.5).fill()
    }
    override func mouseDown(with event:NSEvent) {
        guard let owner else{return};let point=convert(event.locationInWindow,from:nil)
        dragOffset=owner.thumb.contains(point) ? point.x-owner.thumb.minX:owner.thumb.width/2
        mouseDragged(with:event)
    }
    override func mouseDragged(with event:NSEvent) {
        guard let owner else{return};let x=convert(event.locationInWindow,from:nil).x-dragOffset
        let travel=max(1,bounds.width-owner.thumb.width),total=owner.documentView?.bounds.width ?? 0
        owner.scroll(to:x/travel*max(0,total-owner.contentView.bounds.width))
    }
}
