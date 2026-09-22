import AppKit

/// Foundation's CommonMark parser and native TextKit rendering. No browser process.
@MainActor
final class NativeMarkdownView:NSView,NSTextViewDelegate {
    private let scroll=NSScrollView(), text=NSTextView()
    private var generation=0
    private var parsing=false
    private var pending:String?
    private var markdown=""
    private var theme=Theme.all[0]
    var onOpen:((URL)->Void)?
    override init(frame:NSRect) {
        super.init(frame:frame)
        text.isEditable=false;text.isSelectable=true;text.isRichText=true;text.drawsBackground=false;text.delegate=self
        text.textContainerInset=NSSize(width:36,height:24);text.isVerticallyResizable=true;text.isHorizontallyResizable=false
        text.maxSize=NSSize(width:10_000_000,height:10_000_000);text.autoresizingMask=[.width];text.textContainer?.widthTracksTextView=true;text.textContainer?.containerSize=NSSize(width:frame.width,height:10_000_000)
        scroll.documentView=text;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false
        addSubview(scroll)
        text.setAccessibilityLabel("Rendered Markdown document")
    }
    required init?(coder:NSCoder) {fatalError("Use init(frame:)")}
    override func layout() {
        super.layout()
        scroll.frame=bounds;text.frame.size.width=scroll.contentSize.width
    }
    func applyTheme(_ value:Theme) {let changed=theme.name != value.name;theme=value;wantsLayer=true;layer?.backgroundColor=value.background.cgColor;if changed && !markdown.isEmpty {render(markdown)}}
    func render(_ value:String) {
        generation+=1;markdown=value;pending=value
        if !parsing {parseLatest()}
    }
    private func parseLatest() {
        guard let value=pending else{return};pending=nil
        guard value.utf8.count<=5*1024*1024 else {text.string="This document is too large for preview. Choose Source to view the complete file.";return}
        parsing=true;let revision=generation
        Task { [weak self] in
            let parsed=await Task.detached(priority:.userInitiated) { try? AttributedString(markdown:value,options:.init(interpretedSyntax:.full,failurePolicy:.returnPartiallyParsedIfPossible)) }.value
            guard let self else{return};self.parsing=false
            if self.generation==revision {
                let position=self.scroll.contentView.bounds.origin
                let rendered=parsed.map{MarkdownRenderer.render($0,theme:self.theme)} ?? NSAttributedString(string:value)
                self.text.textStorage?.setAttributedString(rendered);self.text.sizeToFit()
                self.scroll.contentView.scroll(to:position);self.scroll.reflectScrolledClipView(self.scroll.contentView)
            }
            self.parseLatest()
        }
    }
    func textView(_ textView:NSTextView,clickedOnLink link:Any,at charIndex:Int)->Bool {
        let url=(link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else{return true}
        if ["https","http","mailto"].contains(url.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(url)}
        else if url.isFileURL {onOpen?(url)}
        return true
    }
}

@MainActor
enum MarkdownRenderer {
    static func render(_ parsed:AttributedString,theme:Theme)->NSAttributedString {
        let output=NSMutableAttributedString(string:"");var previousBlock:Int?
        for run in parsed.runs {
            var content=String(parsed[run.range].characters)
            let components=run.presentationIntent?.components ?? []
            let block=components.first?.identity
            let isNewBlock=block != previousBlock
            if isNewBlock,!output.string.isEmpty {output.append(NSAttributedString(string:"\n\n"))}
            previousBlock=block
            var size:CGFloat=15,weight:NSFont.Weight = .regular,mono=false,color=theme.foreground
            let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=5;paragraph.paragraphSpacing=6
            for component in components {
                switch component.kind {
                case .header(let level):size=CGFloat(max(17,30-level*3));weight = .semibold;color=level==1 ? theme.accentColor:theme.foreground
                case .codeBlock:mono=true;size=13;color=NSColor(hex:theme.string);paragraph.headIndent=14;paragraph.firstLineHeadIndent=14
                case .blockQuote:color=NSColor(hex:theme.muted);paragraph.headIndent=18;paragraph.firstLineHeadIndent=18
                case .listItem(let ordinal):if isNewBlock {content="\(ordinal).  "+content};paragraph.headIndent=22
                case .unorderedList:if isNewBlock,let dot=content.range(of:".  "){content="•  "+content[dot.upperBound...]}
                default:break
                }
            }
            let intent=run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) {weight = .bold}
            if intent.contains(.code) {mono=true;size=13;color=NSColor(hex:theme.string)}
            var font=mono ? NSFont.monospacedSystemFont(ofSize:size,weight:weight):NSFont.systemFont(ofSize:size,weight:weight)
            if intent.contains(.emphasized) {font=NSFontManager.shared.convert(font,toHaveTrait:.italicFontMask)}
            var attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:color,.paragraphStyle:paragraph]
            if intent.contains(.strikethrough) {attributes[.strikethroughStyle]=NSUnderlineStyle.single.rawValue}
            if let link=run.link {attributes[.link]=link;attributes[.foregroundColor]=theme.accentColor}
            output.append(NSAttributedString(string:content,attributes:attributes))
        }
        return output
    }
}

extension EditorWindowController {
    func showWelcome() {
        if let index=documents.firstIndex(where:{$0.isWelcome}) {selectDocument(index);return}
        guard let url=Bundle.main.url(forResource:"Welcome",withExtension:"md"),let content=try? String(contentsOf:url) else{return}
        let d=DocumentTab();d.isWelcome=true;d.previewingMarkdown=true;d.language=LanguageRegistry.shared.language(for:url,text:content)
        if documents.count==1,let first=documents.first,first.url==nil,!first.isModified,first.editor.text.isEmpty {documents=[];first.editor.removeFromSuperview();selected = -1}
        documents.append(d);configureEditor(d);d.editor.text=content;d.editor.markSaved();configureLanguage(d);selectDocument(documents.count-1)
    }
}
