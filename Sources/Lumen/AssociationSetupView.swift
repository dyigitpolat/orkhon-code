import AppKit

/// Selection is independent of filtering and collapsed groups. Search cannot
/// accidentally discard opt-outs, and group actions never enable protected types.
struct AssociationSelection {
    let choices:[AssociationChoice]
    private(set) var selected:Set<String>
    init(_ choices:[AssociationChoice]) {self.choices=choices;selected=Set(choices.filter(\.eligible).map{$0.type.identifier})}
    mutating func toggle(_ choice:AssociationChoice) {guard choice.eligible else{return};if !selected.insert(choice.type.identifier).inserted {selected.remove(choice.type.identifier)}}
    mutating func set(_ choices:[AssociationChoice],enabled:Bool) {for choice in choices where choice.eligible {if enabled {selected.insert(choice.type.identifier)} else {selected.remove(choice.type.identifier)}}}
    var chosen:[AssociationChoice] {choices.filter{$0.eligible && selected.contains($0.type.identifier)}}
    var extensionCount:Int {Set(chosen.flatMap(\.extensions)).count}
    func matching(_ query:String)->[AssociationChoice] {
        let query=query.trimmingCharacters(in:.whitespacesAndNewlines)
        return choices.filter{query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.currentName.localizedCaseInsensitiveContains(query)}
    }
}

private final class AssociationFlippedView:NSView {override var isFlipped:Bool {true}}
private final class AssociationCard:NSView {
    override var isFlipped:Bool {true}
    override func draw(_ rect:NSRect) {
        NSColor.labelColor.withAlphaComponent(0.035).setFill();let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:12,yRadius:12);shape.fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke();shape.lineWidth=1;shape.stroke()
    }
}
private final class AssociationFormatButton:NSButton {
    var accent=NSColor(hex:0x529F94)
    override func draw(_ rect:NSRect) {
        let selected=state == .on
        let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:7,yRadius:7)
        (selected ? accent.withAlphaComponent(isHighlighted ? 0.24:0.13):NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.07:0.025)).setFill();shape.fill()
        (selected ? accent.withAlphaComponent(0.5):NSColor.separatorColor.withAlphaComponent(0.4)).setStroke();shape.lineWidth=1;shape.stroke()
        let symbol = !isEnabled ? "lock.fill":(selected ? "checkmark.circle.fill":"circle")
        let image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:13,weight:.medium))
        let color = !isEnabled ? NSColor.tertiaryLabelColor:(selected ? accent:NSColor.secondaryLabelColor)
        if let image {let tinted=NSImage(size:image.size,flipped:false) { area in image.draw(in:area);color.setFill();area.fill(using:.sourceAtop);return true };tinted.draw(in:NSRect(x:10,y:(bounds.height-14)/2,width:14,height:14))}
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
        let font=NSFont.monospacedSystemFont(ofSize:12,weight:.medium)
        let attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:isEnabled ? NSColor.labelColor:NSColor.secondaryLabelColor,.paragraphStyle:paragraph]
        let height=ceil(font.ascender-font.descender)+2
        (title as NSString).draw(in:NSRect(x:31,y:(bounds.height-height)/2,width:bounds.width-40,height:height),withAttributes:attrs)
        if window?.firstResponder === self {NSFocusRingPlacement.only.set();shape.fill()}
    }
}

@MainActor
final class FirstLaunchSetup:NSWindowController,NSTextFieldDelegate {
    private var selection:AssociationSelection
    private let search=CenteredTextField(frame:.zero),scroll=NSScrollView(),rows=AssociationFlippedView()
    private let actionButton=PillButton(title:"Use selected defaults",target:nil,action:nil)
    private let skipButton=NSButton(title:"Keep all current defaults",target:nil,action:nil)
    private let statusLabel=NSTextField(labelWithString:"")
    private var formatButtons:[AssociationFormatButton]=[],groupButtons:[NSButton]=[]
    private var collapsed=Set<String>()
    private var displayedGroups:[[AssociationChoice]]=[]
    private var groupKeys:[String]=[]
    private var busy=false
    private let onFinish:()->Void
    init(parent:NSWindow,onFinish:@escaping ()->Void) {
        selection=AssociationSelection(FileAssociations.choices());self.onFinish=onFinish
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:744,height:656),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:panel);panel.title="Set up Orkhon Code";panel.titleVisibility = .hidden;panel.titlebarAppearsTransparent=true;panel.isReleasedWhenClosed=false;panel.appearance=parent.effectiveAppearance
        let content=NSView();panel.contentView=content
        let kicker=NSTextField(labelWithString:"FILE DEFAULTS");kicker.font = .systemFont(ofSize:10,weight:.semibold);kicker.textColor=NSColor(hex:0x529F94);kicker.frame=NSRect(x:30,y:612,width:500,height:16)
        let title=NSTextField(labelWithString:"Choose what opens in Orkhon");title.font = .systemFont(ofSize:25,weight:.semibold);title.frame=NSRect(x:28,y:573,width:688,height:34)
        let detail=NSTextField(wrappingLabelWithString:"Grouped by the app that opens them now. Uncheck any formats you want to keep there. Your choices take effect only when you confirm.");detail.font = .systemFont(ofSize:13);detail.textColor = .secondaryLabelColor;detail.frame=NSRect(x:30,y:526,width:680,height:38)
        let searchSurface=Surface(frame:NSRect(x:28,y:479,width:688,height:34));searchSurface.wantsLayer=true;searchSurface.layer?.cornerRadius=8;searchSurface.layer?.borderWidth=1;searchSurface.layer?.borderColor=NSColor.separatorColor.withAlphaComponent(0.6).cgColor;searchSurface.color(NSColor.labelColor.withAlphaComponent(0.035))
        let magnifier=NSImageView(frame:NSRect(x:12,y:9,width:16,height:16));magnifier.image=NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:nil);magnifier.contentTintColor = .secondaryLabelColor;searchSurface.addSubview(magnifier)
        search.frame=NSRect(x:37,y:1,width:638,height:32);search.placeholderString="Search extensions or apps";search.font = .systemFont(ofSize:13);search.isBordered=false;search.drawsBackground=false;search.focusRingType = .none;search.delegate=self;search.setAccessibilityLabel("Search file defaults");searchSurface.addSubview(search)
        scroll.frame=NSRect(x:24,y:112,width:696,height:355);scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false;scroll.documentView=rows
        statusLabel.frame=NSRect(x:30,y:82,width:680,height:18);statusLabel.font = .systemFont(ofSize:11);statusLabel.textColor = .secondaryLabelColor;statusLabel.lineBreakMode = .byTruncatingTail
        let separator=NSBox(frame:NSRect(x:28,y:68,width:688,height:1));separator.boxType = .separator
        skipButton.frame=NSRect(x:22,y:22,width:205,height:34);skipButton.isBordered=false;skipButton.font = .systemFont(ofSize:12);skipButton.target=self;skipButton.action=#selector(skip)
        actionButton.frame=NSRect(x:436,y:20,width:280,height:36);actionButton.font = .systemFont(ofSize:12,weight:.semibold);actionButton.accent=NSColor(hex:0x529F94);actionButton.state = .on;actionButton.target=self;actionButton.action=#selector(applySelection)
        for view in [kicker,title,detail,searchSurface,scroll,statusLabel,separator,skipButton,actionButton] {content.addSubview(view)}
        let byApp=Dictionary(grouping:selection.choices){$0.observed?.lowercased() ?? ""}
        collapsed=Set(byApp.filter{key,values in key=="app.orkhon.editor" || values.allSatisfy{!$0.eligible}}.keys)
        rebuildGroups();updateSummary()
    }
    required init?(coder:NSCoder) {fatalError("Use init(parent:onFinish:)")}
    func present(on parent:NSWindow) {guard let window else{return};parent.beginSheet(window);window.makeFirstResponder(search)}
    func controlTextDidChange(_ notification:Notification) {rebuildGroups(resetScroll:true)}
    private func rebuildGroups(resetScroll:Bool=false) {
        let position=scroll.contentView.bounds.origin
        rows.subviews.forEach{$0.removeFromSuperview()};formatButtons=[];groupButtons=[]
        let filtered=selection.matching(search.stringValue)
        let grouped=Dictionary(grouping:filtered){$0.observed?.lowercased() ?? ""}
        func priority(_ key:String)->Int {
            if grouped[key]!.allSatisfy({!$0.eligible}) {return 3}
            if key.isEmpty {return 2}
            return key=="app.orkhon.editor" ? 1:0
        }
        groupKeys=grouped.keys.sorted {
            if priority($0) != priority($1) {return priority($0)<priority($1)}
            return grouped[$0]!.first!.currentName.localizedStandardCompare(grouped[$1]!.first!.currentName) == .orderedAscending
        }
        displayedGroups=groupKeys.map{grouped[$0]!}
        let width:CGFloat=688;var y:CGFloat=0
        for (index,choices) in displayedGroups.enumerated() {
            let key=groupKeys[index],first=choices[0],card=AssociationCard(frame:.zero)
            let isCollapsed=collapsed.contains(key) && search.stringValue.isEmpty
            let disclosure=NSButton(image:NSImage(systemSymbolName:isCollapsed ? "chevron.right":"chevron.down",accessibilityDescription:"Expand or collapse \(first.currentName)") ?? NSImage(),target:self,action:#selector(toggleGroupVisibility(_:)))
            disclosure.isBordered=false;disclosure.tag=index;disclosure.frame=NSRect(x:9,y:18,width:20,height:22);card.addSubview(disclosure);groupButtons.append(disclosure)
            let icon=NSImageView(frame:NSRect(x:34,y:15,width:30,height:30))
            if let app=first.observed.flatMap({NSWorkspace.shared.urlForApplication(withBundleIdentifier:$0)}) {icon.image=NSWorkspace.shared.icon(forFile:app.path)}
            else {icon.image=NSImage(systemSymbolName:"doc.text",accessibilityDescription:nil);icon.contentTintColor = .secondaryLabelColor}
            card.addSubview(icon)
            let label=NSTextField(labelWithString:first.currentName);label.font = .systemFont(ofSize:13,weight:.semibold);label.frame=NSRect(x:74,y:12,width:width-235,height:19);label.lineBreakMode = .byTruncatingTail;card.addSubview(label)
            let count=Set(choices.flatMap(\.extensions)).count,chosen=choices.filter{selection.selected.contains($0.type.identifier)},chosenCount=Set(chosen.flatMap(\.extensions)).count
            let subtitle=NSTextField(labelWithString:"\(count) \(count==1 ? "extension":"extensions") · \(chosenCount) selected"+(choices.allSatisfy{!$0.eligible} ? " · kept with this app":""));subtitle.font = .systemFont(ofSize:11);subtitle.textColor = .secondaryLabelColor;subtitle.frame=NSRect(x:74,y:32,width:width-210,height:16);card.addSubview(subtitle)
            if choices.contains(where:{$0.eligible}) {
                let all=choices.filter(\.eligible).allSatisfy{selection.selected.contains($0.type.identifier)}
                let toggle=NSButton(title:all ? "Keep current":"Use Orkhon",target:self,action:#selector(toggleGroupSelection(_:)));toggle.isBordered=false;toggle.font = .systemFont(ofSize:11,weight:.medium);toggle.contentTintColor=NSColor(hex:0x529F94);toggle.tag=index;toggle.frame=NSRect(x:width-122,y:18,width:106,height:25);toggle.toolTip=all ? "Unselect this group":"Select eligible formats in this group";card.addSubview(toggle);groupButtons.append(toggle)
            }
            var bottom:CGFloat=60
            if !isCollapsed {
                var x:CGFloat=14,top:CGFloat=61
                for choice in choices {
                    let font=NSFont.monospacedSystemFont(ofSize:12,weight:.medium)
                    let w=min(width-28,max(84,ceil((choice.label as NSString).size(withAttributes:[.font:font]).width)+43))
                    if x+w>width-14 {x=14;top+=38}
                    let button=AssociationFormatButton(title:choice.label,target:self,action:#selector(toggleFormat(_:)));button.setButtonType(.switch);button.isBordered=false;button.state=selection.selected.contains(choice.type.identifier) ? .on:.off;button.isEnabled=choice.eligible && !busy;button.identifier=NSUserInterfaceItemIdentifier(choice.type.identifier);button.frame=NSRect(x:x,y:top,width:w,height:31);button.setAccessibilityLabel("\(choice.label), currently \(choice.currentName)");button.toolTip=choice.reason ?? "\(choice.label) · These extensions share one macOS default";card.addSubview(button);formatButtons.append(button);x+=w+7
                }
                bottom=top+45
            }
            card.frame=NSRect(x:0,y:y,width:width,height:bottom);rows.addSubview(card);y+=bottom+10
        }
        if filtered.isEmpty {let empty=NSTextField(labelWithString:"No matching extensions or apps");empty.textColor = .secondaryLabelColor;empty.alignment = .center;empty.frame=NSRect(x:0,y:60,width:width,height:22);rows.addSubview(empty);y=150}
        rows.frame=NSRect(x:0,y:0,width:width,height:max(scroll.contentSize.height,y))
        scroll.contentView.scroll(to:resetScroll ? .zero:NSPoint(x:0,y:min(position.y,max(0,y-scroll.contentSize.height))));scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func toggleFormat(_ sender:NSButton) {
        guard !busy,let id=sender.identifier?.rawValue,let choice=selection.choices.first(where:{$0.type.identifier==id}) else{return}
        selection.toggle(choice);rebuildGroups();updateSummary()
    }
    @objc private func toggleGroupVisibility(_ sender:NSButton) {guard !busy,groupKeys.indices.contains(sender.tag) else{return};let key=groupKeys[sender.tag];if !collapsed.insert(key).inserted {collapsed.remove(key)};rebuildGroups()}
    @objc private func toggleGroupSelection(_ sender:NSButton) {
        guard !busy,displayedGroups.indices.contains(sender.tag) else{return};let group=displayedGroups[sender.tag]
        let all=group.filter(\.eligible).allSatisfy{selection.selected.contains($0.type.identifier)}
        selection.set(group,enabled:!all);rebuildGroups();updateSummary()
    }
    private func updateSummary() {
        let count=selection.extensionCount
        if !FileAssociations.canApply {
            actionButton.title="Install to change defaults";actionButton.isEnabled=false
            statusLabel.stringValue="Preview build · These choices are read-only until Orkhon Code is installed."
            skipButton.title="Continue to editor";return
        }
        actionButton.title=count==0 ? "Continue without changes":"Use Orkhon for \(count) extensions"
        statusLabel.stringValue="\(count) selected · Browser and media defaults stay unchanged. C++ includes .cp."
    }
    @objc private func skip() {guard !busy else{return};finish()}
    @objc private func applySelection() {
        guard !busy,FileAssociations.canApply else{return};let selected=selection.chosen
        if selected.isEmpty {finish();return}
        busy=true;search.isEnabled=false;actionButton.isEnabled=false;skipButton.isEnabled=false;formatButtons.forEach{$0.isEnabled=false};groupButtons.forEach{$0.isEnabled=false};statusLabel.stringValue="Applying your choices…"
        Task { [weak self] in
            let failures=await FileAssociations.apply(selected)
            guard let self else{return};self.busy=false
            if failures.isEmpty {self.finish()}
            else {
                self.skipButton.isEnabled=true;self.skipButton.title="Continue to editor";self.statusLabel.stringValue="Some choices were not changed."
                let alert=NSAlert();alert.messageText="macOS could not apply every choice";alert.informativeText=failures.joined(separator:"\n");alert.addButton(withTitle:"OK")
                if let window=self.window {alert.beginSheetModal(for:window,completionHandler:nil)}
            }
        }
    }
    private func finish() {UserDefaults.standard.set(true,forKey:"fileSetupCompletedV6");if let window {window.sheetParent?.endSheet(window);window.orderOut(nil)};onFinish()}
}
