import AppKit

final class SecureCell:NSSecureTextFieldCell {
    override func drawingRect(forBounds rect:NSRect)->NSRect {
        var area=super.drawingRect(forBounds:rect);let height=ceil((font?.ascender ?? 13)-(font?.descender ?? -3))+2
        area.origin.y+=floor((area.height-height)/2);area.size.height=min(height,area.height);return area
    }
    override func edit(withFrame rect:NSRect,in controlView:NSView,editor:NSText,delegate:Any?,event:NSEvent?) {super.edit(withFrame:drawingRect(forBounds:rect),in:controlView,editor:editor,delegate:delegate,event:event)}
    override func select(withFrame rect:NSRect,in controlView:NSView,editor:NSText,delegate:Any?,start:Int,length:Int) {super.select(withFrame:drawingRect(forBounds:rect),in:controlView,editor:editor,delegate:delegate,start:start,length:length)}
}
final class Authentication:NSObject,NSWindowDelegate {
    let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:500,height:304),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
    let input=NSSecureTextField()
    let hostVerification=CommandLine.arguments.dropFirst().joined(separator:" ").contains("Are you sure you want to continue connecting")
    var confirm:Bool {hostVerification || ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] == "confirm"}
    var accepted=false
    override init() {
        super.init();panel.title="Orkhon · SSH Authentication";panel.titleVisibility = .hidden;panel.titlebarAppearsTransparent=true;panel.isReleasedWhenClosed=false;panel.delegate=self
        let content=NSView();panel.contentView=content
        let title=NSTextField(labelWithString:hostVerification ? "Verify this server":(confirm ? "Approve SSH request":"SSH authentication"))
        title.font = .systemFont(ofSize:23,weight:.semibold);title.frame=NSRect(x:28,y:245,width:440,height:32);content.addSubview(title)
        let prompt=NSTextField(wrappingLabelWithString:CommandLine.arguments.dropFirst().joined(separator:" "))
        prompt.font = .systemFont(ofSize:12);prompt.textColor = .secondaryLabelColor;prompt.frame=NSRect(x:30,y:132,width:438,height:98);content.addSubview(prompt)
        input.cell=SecureCell(textCell:"");input.isEditable=true;input.isSelectable=true;input.cell?.usesSingleLineMode=true;input.setAccessibilityLabel("Password or passphrase");input.font = .systemFont(ofSize:14);input.isBezeled=false;input.isBordered=false;input.focusRingType = .none;input.placeholderString="Password or passphrase";input.frame=NSRect(x:40,y:87,width:420,height:36)
        let surface=NSView(frame:NSRect(x:28,y:87,width:444,height:36));surface.wantsLayer=true;surface.layer?.cornerRadius=7;surface.layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor;surface.layer?.borderWidth=1;surface.layer?.borderColor=NSColor.separatorColor.cgColor
        if !confirm {content.addSubview(surface);content.addSubview(input)}
        let cancel=NSButton(title:"Cancel",target:self,action:#selector(cancel));cancel.bezelStyle = .rounded;cancel.frame=NSRect(x:260,y:26,width:88,height:32);cancel.keyEquivalent="\u{1b}";content.addSubview(cancel)
        let submit=NSButton(title:hostVerification ? "Trust server":"Continue",target:self,action:#selector(submit));submit.bezelStyle = .rounded;submit.frame=NSRect(x:354,y:26,width:120,height:32);submit.keyEquivalent="\r";content.addSubview(submit)
        panel.initialFirstResponder=confirm ? submit:input
        panel.center()
        // A cancelled connection must not leave an orphan password dialog behind.
        let timer=Timer(timeInterval:0.3,repeats:true) { [weak self] timer in
            if getppid()==1 {timer.invalidate();self?.cancel()}
        }
        RunLoop.main.add(timer,forMode:.modalPanel)
        RunLoop.main.add(timer,forMode:.common)
    }
    @objc func submit() {accepted=true;NSApp.stopModal()}
    @objc func cancel() {NSApp.abortModal()}
    func windowShouldClose(_ sender:NSWindow)->Bool {cancel();return false}
}
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
let menu=NSMenu(),editItem=NSMenuItem(title:"Edit",action:nil,keyEquivalent:""),editMenu=NSMenu(title:"Edit")
let appItem=NSMenuItem(title:"Orkhon SSH Authentication",action:nil,keyEquivalent:"");appItem.submenu=NSMenu(title:"Orkhon SSH Authentication");menu.addItem(appItem)
for (title,selector,key) in [("Paste","paste:","v"),("Select All","selectAll:","a")] {let item=NSMenuItem(title:title,action:NSSelectorFromString(selector),keyEquivalent:key);item.target=nil;editMenu.addItem(item)}
editItem.submenu=editMenu;menu.addItem(editItem);app.mainMenu=menu
let auth=Authentication()
app.activate(ignoringOtherApps:true);auth.panel.makeKeyAndOrderFront(nil)
app.runModal(for:auth.panel)
if auth.accepted {
    let response=auth.confirm ? "yes":auth.input.stringValue
    FileHandle.standardOutput.write(Data((response+"\n").utf8));auth.input.stringValue=""
    exit(0)
}
exit(1)
