#import "include/EditorBridge.h"
#import "ScintillaView.h"
#include "ILexer.h"
#include "Lexilla.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <set>
#include <string>
#include <vector>
#include "LexerStyleNames.inc"

namespace {
sptr_t Sci(ScintillaView *view, unsigned int message, uptr_t w = 0, sptr_t l = 0) {
    return [view message:message wParam:w lParam:l];
}

sptr_t Pointer(const void *value) { return reinterpret_cast<sptr_t>(value); }

NSString *StyleMetadata(ScintillaView *view, unsigned int message, NSInteger style) {
    const sptr_t length = Sci(view, message, style);
    if (length <= 0) return @"";
    std::vector<char> buffer(static_cast<size_t>(length) + 1, 0);
    Sci(view, message, style, Pointer(buffer.data()));
    return [[NSString alloc] initWithBytes:buffer.data() length:length
                                encoding:NSUTF8StringEncoding] ?: @"";
}

NSInteger SearchFlags(BOOL matchCase, BOOL regex, BOOL wholeWord) {
    return (matchCase ? SCFIND_MATCHCASE : 0) | (wholeWord ? SCFIND_WHOLEWORD : 0) |
           (regex ? SCFIND_REGEXP | SCFIND_CXX11REGEX : 0);
}

unsigned int Colour(NSColor *colour, BOOL alpha = NO) {
    NSColor *rgb = [colour colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.blackColor;
    auto byte = [](CGFloat component) {
        return static_cast<unsigned int>(std::lround(std::clamp(component, CGFloat(0), CGFloat(1)) * 255));
    };
    return byte(rgb.redComponent) | (byte(rgb.greenComponent) << 8) |
           (byte(rgb.blueComponent) << 16) | (alpha ? byte(rgb.alphaComponent) << 24 : 0);
}

BOOL ContainsAny(NSString *text, NSArray<NSString *> *terms) {
    for (NSString *term in terms) if ([text containsString:term]) return YES;
    return NO;
}

// Classify the lexer's published style metadata, never the document's source text.
NSString *PaletteKey(NSString *tags, NSString *name, NSString *description) {
    NSString *metadata = [NSString stringWithFormat:@"%@ %@ %@", tags, name, description].lowercaseString;
    if (ContainsAny(metadata, @[@"header", @"strong", @"bold"])) return @"keyword";
    if (ContainsAny(metadata, @[@"_code", @"backtick"])) return @"string";
    if (ContainsAny(metadata, @[@"_link", @"_ulist", @"_olist", @"_table", @"_key", @"blockquote"])) return @"accent";
    if (ContainsAny(metadata, @[@"_em1", @"_em2", @"emphasis", @"_date"])) return @"type";
    if (ContainsAny(metadata, @[@"comment", @"documentation"])) return @"comment";
    if (ContainsAny(metadata, @[@"string", @"character", @"regex", @"verbatim", @"heredoc", @"quoted"])) return @"string";
    if (ContainsAny(metadata, @[@"number", @"numeric", @"_hex", @"_binary", @"_octal"])) return @"number";
    if (ContainsAny(metadata, @[@"type", @"class", @"_word2", @"keywords2", @"highlighted identifiers"])) return @"type";
    if (ContainsAny(metadata, @[@"keyword", @"_word"])) return @"keyword";
    if (ContainsAny(metadata, @[@"operator", @"punctuation", @"_symbol", @"_group", @"_special"])) return @"operator";
    if (ContainsAny(metadata, @[@"preprocessor", @"directive", @"decorator", @"_command", @"_instruction"])) return @"keyword";
    if (ContainsAny(metadata, @[@"function", @"method", @"defname", @"tag", @"attribute", @"label"])) return @"accent";
    return @"foreground";
}
} // namespace

@interface LMEditorView () <ScintillaNotificationProtocol> {
    ScintillaView *_editor; // ARC strong, independent of how upstream is compiled.
    NSDictionary<NSString *, NSColor *> *_palette;
    BOOL _callbacksScheduled;
    BOOL _pendingChange;
    BOOL _pendingUpdate;
    NSString *_lexerName;
    NSString *_lastSearchQuery;
    NSInteger _lastSearchFlags;
    NSInteger _lastSearchPosition;
    BOOL _lastSearchBackwards;
}
@end

@implementation LMEditorView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self configureEditor];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self configureEditor];
    return self;
}

- (void)configureEditor {
    NSAssert(NSThread.isMainThread, @"LMEditorView must be used on the main thread");
    _lastSearchPosition = -1;
    _editor = [[ScintillaView alloc] initWithFrame:self.bounds];
    _editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_editor];

    Sci(_editor, SCI_SETCODEPAGE, SC_CP_UTF8);
    Sci(_editor, SCI_SETIDLESTYLING, SC_IDLESTYLING_TOVISIBLE);
    Sci(_editor, SCI_SETEOLMODE, SC_EOL_LF);
    Sci(_editor, SCI_SETMARGINTYPEN, 0, SC_MARGIN_NUMBER);
    Sci(_editor, SCI_SETMARGINWIDTHN, 1, 0);
    Sci(_editor, SCI_SETMARGINTYPEN, 2, SC_MARGIN_SYMBOL);
    Sci(_editor, SCI_SETMARGINMASKN, 2, SC_MASK_FOLDERS);
    Sci(_editor, SCI_SETMARGINWIDTHN, 2, 16);
    Sci(_editor, SCI_SETMARGINSENSITIVEN, 2, YES);
    Sci(_editor, SCI_SETMARGINCURSORN, 2, SC_CURSORARROW);
    Sci(_editor, SCI_SETMARGINLEFT, 0, 8);
    Sci(_editor, SCI_SETMARGINRIGHT, 0, 8);
    const int markers[][2] = {
        {SC_MARKNUM_FOLDER, SC_MARK_BOXPLUS}, {SC_MARKNUM_FOLDEROPEN, SC_MARK_BOXMINUS},
        {SC_MARKNUM_FOLDEREND, SC_MARK_BOXPLUSCONNECTED},
        {SC_MARKNUM_FOLDEROPENMID, SC_MARK_BOXMINUSCONNECTED},
        {SC_MARKNUM_FOLDERMIDTAIL, SC_MARK_TCORNER}, {SC_MARKNUM_FOLDERTAIL, SC_MARK_LCORNER},
        {SC_MARKNUM_FOLDERSUB, SC_MARK_VLINE},
    };
    for (const auto &marker : markers) Sci(_editor, SCI_MARKERDEFINE, marker[0], marker[1]);
    // Native fold clicks also handle modifier keys; don't toggle them again in the delegate.
    Sci(_editor, SCI_SETAUTOMATICFOLD, SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE);
    Sci(_editor, SCI_SETMULTIPLESELECTION, YES);
    Sci(_editor, SCI_SETADDITIONALSELECTIONTYPING, YES);
    Sci(_editor, SCI_SETADDITIONALCARETSBLINK, YES);
    Sci(_editor, SCI_SETMULTIPASTE, SC_MULTIPASTE_EACH);
    Sci(_editor, SCI_SETMOUSESELECTIONRECTANGULARSWITCH, YES);
    Sci(_editor, SCI_SETRECTANGULARSELECTIONMODIFIER, SCMOD_ALT);
    Sci(_editor, SCI_SETVIRTUALSPACEOPTIONS, SCVS_RECTANGULARSELECTION);
    Sci(_editor, SCI_SETTABINDENTS, YES);
    Sci(_editor, SCI_SETBACKSPACEUNINDENTS, YES);
    Sci(_editor, SCI_SETINDENT, 0); // Follow tabWidth.
    Sci(_editor, SCI_SETINDENTATIONGUIDES, SC_IV_LOOKBOTH);
    Sci(_editor, SCI_SETLAYOUTCACHE, SC_CACHE_PAGE);
    Sci(_editor, SCI_SETSCROLLWIDTH, 1);
    Sci(_editor, SCI_SETSCROLLWIDTHTRACKING, YES);
    Sci(_editor, SCI_SETWRAPVISUALFLAGS, SC_WRAPVISUALFLAG_END);
    Sci(_editor, SCI_SETWRAPINDENTMODE, SC_WRAPINDENT_SAME);
    Sci(_editor, SCI_SETCARETWIDTH, 2);
    Sci(_editor, SCI_SETCARETLINEVISIBLE, YES);
    Sci(_editor, SCI_SETCARETLINEVISIBLEALWAYS, YES);
    Sci(_editor, SCI_SETPHASESDRAW, SC_PHASES_MULTIPLE);
    Sci(_editor, SCI_SETSELECTIONLAYER, SC_LAYER_UNDER_TEXT);
    Sci(_editor, SCI_SETCARETLINELAYER, SC_LAYER_BASE);
    Sci(_editor, SCI_SETFONTQUALITY, SC_EFF_QUALITY_ANTIALIASED);
    self.tabWidth = 4;
    self.useTabs = NO;
    self.fontSize = 13;
    [self setLexer:@"null" keywords:@[] properties:@{}];
    [self applyPalette:@{}];
    [self markSaved];
    // Keep Scintilla's Cocoa key map and responder handling (Cmd-C/V/X/A/Z, etc.).
    _editor.delegate = self;
}

- (void)dealloc {
    // Upstream's delegate is unsafe_unretained, not weak.
    _editor.delegate = nil;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { return [self.window makeFirstResponder:_editor.content]; }
- (void)focus { [self.window makeFirstResponder:_editor.content]; }

- (NSInteger)send:(NSInteger)message w:(NSInteger)w l:(NSInteger)l {
    NSAssert(NSThread.isMainThread, @"LMEditorView must be used on the main thread");
    return Sci(_editor, static_cast<unsigned int>(message), static_cast<uptr_t>(w), static_cast<sptr_t>(l));
}

- (void)command:(NSInteger)message { [self send:message w:0 l:0]; }

- (NSString *)text {
    const NSInteger length = Sci(_editor, SCI_GETLENGTH);
    std::vector<char> buffer(static_cast<size_t>(length) + 1, 0);
    Sci(_editor, SCI_GETTEXT, buffer.size(), Pointer(buffer.data()));
    return [[NSString alloc] initWithBytes:buffer.data() length:length encoding:NSUTF8StringEncoding] ?: @"";
}

- (void)setText:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    const BOOL readOnly = Sci(_editor, SCI_GETREADONLY);
    Sci(_editor, SCI_SETREADONLY, NO);
    Sci(_editor, SCI_SETUNDOCOLLECTION, NO);
    Sci(_editor, SCI_SETTARGETRANGE, 0, Sci(_editor, SCI_GETLENGTH));
    Sci(_editor, SCI_REPLACETARGET, data.length, Pointer(data.bytes ?: ""));
    Sci(_editor, SCI_SETUNDOCOLLECTION, YES);
    Sci(_editor, SCI_EMPTYUNDOBUFFER);
    Sci(_editor, SCI_SETSAVEPOINT);
    Sci(_editor, SCI_SETEMPTYSELECTION, 0);
    Sci(_editor, SCI_SETREADONLY, readOnly);
    // Match the loaded document's first line ending without normalizing its bytes.
    NSRange eol = [text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet];
    NSInteger mode = SC_EOL_LF;
    if (eol.location != NSNotFound && [text characterAtIndex:eol.location] == '\r') {
        mode = eol.location + 1 < text.length && [text characterAtIndex:eol.location + 1] == '\n'
             ? SC_EOL_CRLF : SC_EOL_CR;
    }
    Sci(_editor, SCI_SETEOLMODE, mode);
    [self updateLineNumberWidth];
    [self scheduleChange:YES update:YES];
}

- (BOOL)modified { return Sci(_editor, SCI_GETMODIFY) != 0; }
- (NSInteger)currentLine { return Sci(_editor, SCI_LINEFROMPOSITION, Sci(_editor, SCI_GETCURRENTPOS)) + 1; }
- (NSInteger)currentColumn { return Sci(_editor, SCI_GETCOLUMN, Sci(_editor, SCI_GETCURRENTPOS)) + 1; }
- (NSInteger)selectionLength {
    NSInteger length = 0;
    const NSInteger count = Sci(_editor, SCI_GETSELECTIONS);
    for (NSInteger i = 0; i < count; ++i) {
        length += Sci(_editor, SCI_COUNTCHARACTERS, Sci(_editor, SCI_GETSELECTIONNSTART, i),
                      Sci(_editor, SCI_GETSELECTIONNEND, i));
    }
    return length;
}
- (BOOL)wordWrap { return Sci(_editor, SCI_GETWRAPMODE) != SC_WRAP_NONE; }
- (void)setWordWrap:(BOOL)value { Sci(_editor, SCI_SETWRAPMODE, value ? SC_WRAP_WORD : SC_WRAP_NONE); }
- (BOOL)showWhitespace { return Sci(_editor, SCI_GETVIEWWS) != SCWS_INVISIBLE; }
- (void)setShowWhitespace:(BOOL)value { Sci(_editor, SCI_SETVIEWWS, value ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE); }
- (NSInteger)tabWidth { return Sci(_editor, SCI_GETTABWIDTH); }
- (void)setTabWidth:(NSInteger)value { Sci(_editor, SCI_SETTABWIDTH, std::clamp(value, NSInteger(1), NSInteger(32))); }
- (BOOL)useTabs { return Sci(_editor, SCI_GETUSETABS) != 0; }
- (void)setUseTabs:(BOOL)value { Sci(_editor, SCI_SETUSETABS, value); }
- (CGFloat)fontSize { return Sci(_editor, SCI_STYLEGETSIZEFRACTIONAL, STYLE_DEFAULT) / CGFloat(SC_FONT_SIZE_MULTIPLIER); }
- (void)setFontSize:(CGFloat)value {
    if (!std::isfinite(value)) return;
    value = std::clamp(value, CGFloat(6), CGFloat(96));
    NSString *fontName = [NSFont monospacedSystemFontOfSize:value weight:NSFontWeightRegular].fontName;
    for (NSInteger style = 0; style <= STYLE_MAX; ++style) {
        Sci(_editor, SCI_STYLESETFONT, style, Pointer(fontName.UTF8String));
        Sci(_editor, SCI_STYLESETSIZEFRACTIONAL, style, std::lround(value * SC_FONT_SIZE_MULTIPLIER));
    }
    [self updateLineNumberWidth];
}
- (void)markSaved { Sci(_editor, SCI_SETSAVEPOINT); }

- (void)insertRecoveredText:(NSString *)text {
    if (Sci(_editor, SCI_GETREADONLY)) return;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    Sci(_editor, SCI_TARGETFROMSELECTION);
    // Length-aware equivalent of SCI_REPLACESEL, including embedded NULs.
    Sci(_editor, SCI_REPLACETARGET, data.length, Pointer(data.bytes ?: ""));
    Sci(_editor, SCI_SETEMPTYSELECTION, Sci(_editor, SCI_GETTARGETEND));
    [self scheduleChange:NO update:YES];
}

+ (NSArray<NSString *> *)availableLexers {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *result = [NSMutableArray array];
        for (int index = 0; index < GetLexerCount(); ++index) {
            char name[256] = {};
            GetLexerName(index, name, sizeof(name));
            NSString *value = [NSString stringWithUTF8String:name];
            if (value.length) [result addObject:value];
        }
        names = [result sortedArrayUsingSelector:@selector(compare:)];
    });
    return names;
}

- (void)setLexer:(NSString *)name keywords:(NSArray<NSString *> *)keywords
      properties:(NSDictionary<NSString *, NSString *> *)properties {
    _lexerName = [name copy];
    // A fresh instance discards the previous lexer's word lists and properties.
    Scintilla::ILexer5 *lexer = CreateLexer(name.UTF8String);
    if (!lexer) lexer = CreateLexer("null");
    Sci(_editor, SCI_SETILEXER, 0, Pointer(lexer)); // Document owns/releases the instance.
    Sci(_editor, SCI_SETPROPERTY, reinterpret_cast<uptr_t>("fold"), Pointer("1"));
    for (NSString *key in properties) {
        Sci(_editor, SCI_SETPROPERTY, reinterpret_cast<uptr_t>(key.UTF8String), Pointer(properties[key].UTF8String));
    }
    [keywords enumerateObjectsUsingBlock:^(NSString *words, NSUInteger index, BOOL * __unused stop) {
        Sci(self->_editor, SCI_SETKEYWORDS, index, Pointer(words.UTF8String));
    }];
    // This also shows all lines and resets expanded flags/fold levels, so changing
    // lexers cannot leave stale collapsed regions from the previous language.
    Sci(_editor, SCI_CLEARDOCUMENTSTYLE);
    // ClearDocumentStyle writes default styles through EOF. Mark the document
    // unstyled again so native painting/idle work will lex it incrementally.
    Sci(_editor, SCI_STARTSTYLING, 0);
    [self applyPalette:_palette ?: @{}];
    const NSInteger firstVisible = Sci(_editor, SCI_GETFIRSTVISIBLELINE);
    const NSInteger visibleLines = std::max<sptr_t>(1, Sci(_editor, SCI_LINESONSCREEN));
    const NSInteger lineAfterView = std::min(Sci(_editor, SCI_GETLINECOUNT),
        Sci(_editor, SCI_DOCLINEFROMVISIBLE, firstVisible + visibleLines + 1));
    const NSInteger viewportEnd = Sci(_editor, SCI_POSITIONFROMLINE, lineAfterView);
    // Keep correct lexical context by starting at zero. A switch far down a large
    // document (or a huge first line) must not synchronously lex the whole prefix.
    // Native TOVISIBLE idle styling catches up on paint/scroll, without styling EOF.
    constexpr NSInteger initialByteLimit = 64 * 1024;
    const NSInteger end = std::min({(viewportEnd < 0 ? static_cast<NSInteger>(Sci(_editor, SCI_GETLENGTH)) : viewportEnd),
                                   static_cast<NSInteger>(Sci(_editor, SCI_GETLENGTH)), initialByteLimit});
    if (end > 0) Sci(_editor, SCI_COLOURISE, 0, end);
}

- (void)applyPalette:(NSDictionary<NSString *, NSColor *> *)palette {
    _palette = [palette copy];
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [self applyCurrentPalette];
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    if (_editor && _palette) [self applyPalette:_palette];
}

- (void)applyCurrentPalette {
    NSMutableDictionary<NSString *, NSColor *> *colours = [@{
        @"background": NSColor.textBackgroundColor, @"foreground": NSColor.textColor,
        @"muted": NSColor.secondaryLabelColor, @"selection": NSColor.selectedTextBackgroundColor,
        @"line": [NSColor.controlAccentColor colorWithAlphaComponent:0.06],
        @"accent": NSColor.controlAccentColor, @"keyword": NSColor.systemPurpleColor,
        @"string": NSColor.systemGreenColor, @"number": NSColor.systemOrangeColor,
        @"comment": NSColor.secondaryLabelColor, @"type": NSColor.systemTealColor,
        @"operator": NSColor.textColor,
    } mutableCopy];
    [colours addEntriesFromDictionary:_palette];
    const unsigned int background = Colour(colours[@"background"]);
    const unsigned int foreground = Colour(colours[@"foreground"]);
    const unsigned int muted = Colour(colours[@"muted"]);
    Sci(_editor, SCI_STYLESETFORE, STYLE_DEFAULT, foreground);
    Sci(_editor, SCI_STYLESETBACK, STYLE_DEFAULT, background);
    Sci(_editor, SCI_STYLESETBOLD, STYLE_DEFAULT, NO);
    Sci(_editor, SCI_STYLESETITALIC, STYLE_DEFAULT, NO);
    Sci(_editor, SCI_STYLECLEARALL);
    NSMutableDictionary<NSNumber *, NSString *> *fallback = [NSMutableDictionary dictionary];
    for (const auto &entry : upstreamStyles) {
        if ([_lexerName isEqualToString:@(entry.lexer)]) fallback[@(entry.style)] = @(entry.name);
    }
    const NSInteger namedStyles = std::min<sptr_t>(Sci(_editor, SCI_GETNAMEDSTYLES), STYLE_MAX + 1);
    NSMutableSet<NSNumber *> *styles = [NSMutableSet setWithArray:fallback.allKeys];
    for (NSInteger style=0; style<namedStyles; ++style) [styles addObject:@(style)];
    for (NSNumber *styleNumber in styles) {
        NSInteger style = styleNumber.integerValue;
        if (style >= STYLE_DEFAULT && style <= STYLE_LASTPREDEFINED) continue;
        NSString *tags = StyleMetadata(_editor, SCI_TAGSOFSTYLE, style);
        NSString *name = StyleMetadata(_editor, SCI_NAMEOFSTYLE, style);
        NSString *description = StyleMetadata(_editor, SCI_DESCRIPTIONOFSTYLE, style);
        if (!name.length && !tags.length) name = fallback[styleNumber] ?: @"";
        NSString *key = PaletteKey(tags, name, description);
        NSColor *colour = colours[key];
        if ([tags containsString:@"inactive"]) colour = [colour blendedColorWithFraction:0.55 ofColor:colours[@"muted"]] ?: colour;
        Sci(_editor, SCI_STYLESETFORE, style, Colour(colour));
        NSString *metadata = [name stringByAppendingString:description].lowercaseString;
        Sci(_editor, SCI_STYLESETBOLD, style, ContainsAny(metadata,@[@"header",@"strong",@"bold"]));
        Sci(_editor, SCI_STYLESETITALIC, style, [key isEqualToString:@"comment"] || ContainsAny(metadata,@[@"_em1",@"_em2",@"emphasis"]));
    }
    Sci(_editor, SCI_STYLESETFORE, STYLE_LINENUMBER, muted);
    Sci(_editor, SCI_STYLESETBACK, STYLE_LINENUMBER, background);
    Sci(_editor, SCI_STYLESETFORE, STYLE_INDENTGUIDE, muted);
    Sci(_editor, SCI_STYLESETFORE, STYLE_BRACELIGHT, Colour(colours[@"accent"]));
    Sci(_editor, SCI_STYLESETBACK, STYLE_BRACELIGHT, Colour(colours[@"selection"]));
    Sci(_editor, SCI_STYLESETBOLD, STYLE_BRACELIGHT, YES);
    Sci(_editor, SCI_STYLESETFORE, STYLE_BRACEBAD, Colour(NSColor.systemRedColor));
    Sci(_editor, SCI_STYLESETBOLD, STYLE_BRACEBAD, YES);
    for (int marker = SC_MARKNUM_FOLDEREND; marker <= SC_MARKNUM_FOLDEROPEN; ++marker) {
        Sci(_editor, SCI_MARKERSETFORE, marker, background);
        Sci(_editor, SCI_MARKERSETBACK, marker, muted);
        Sci(_editor, SCI_MARKERSETBACKSELECTED, marker, Colour(colours[@"accent"]));
    }
    Sci(_editor, SCI_SETFOLDMARGINCOLOUR, YES, background);
    Sci(_editor, SCI_SETFOLDMARGINHICOLOUR, YES, background);
    const int selectionElements[] = {SC_ELEMENT_SELECTION_BACK, SC_ELEMENT_SELECTION_ADDITIONAL_BACK,
        SC_ELEMENT_SELECTION_SECONDARY_BACK, SC_ELEMENT_SELECTION_INACTIVE_BACK,
        SC_ELEMENT_SELECTION_INACTIVE_ADDITIONAL_BACK};
    for (int element : selectionElements) Sci(_editor, SCI_SETELEMENTCOLOUR, element, Colour(colours[@"selection"], YES));
    const int textElements[] = {SC_ELEMENT_SELECTION_TEXT, SC_ELEMENT_SELECTION_ADDITIONAL_TEXT,
        SC_ELEMENT_SELECTION_SECONDARY_TEXT, SC_ELEMENT_SELECTION_INACTIVE_TEXT,
        SC_ELEMENT_SELECTION_INACTIVE_ADDITIONAL_TEXT};
    for (int element : textElements) Sci(_editor, SCI_RESETELEMENTCOLOUR, element);
    Sci(_editor, SCI_SETELEMENTCOLOUR, SC_ELEMENT_CARET, Colour(colours[@"accent"], YES));
    Sci(_editor, SCI_SETELEMENTCOLOUR, SC_ELEMENT_CARET_ADDITIONAL, Colour(colours[@"accent"], YES));
    Sci(_editor, SCI_SETELEMENTCOLOUR, SC_ELEMENT_CARET_LINE_BACK, Colour(colours[@"line"], YES));
    Sci(_editor, SCI_SETELEMENTCOLOUR, SC_ELEMENT_WHITE_SPACE, Colour(colours[@"muted"], YES));
    _editor.scrollView.backgroundColor = colours[@"background"];
    [self updateLineNumberWidth];
    _editor.needsDisplay = YES;
}

- (void)updateLineNumberWidth {
    if (!_editor) return;
    NSString *digits = [NSString stringWithFormat:@"%ld", (long)Sci(_editor, SCI_GETLINECOUNT)];
    digits = [@"" stringByPaddingToLength:std::max<NSUInteger>(4, digits.length) withString:@"9" startingAtIndex:0];
    const NSInteger width = Sci(_editor, SCI_TEXTWIDTH, STYLE_LINENUMBER, Pointer(digits.UTF8String)) + 16;
    if (width != Sci(_editor, SCI_GETMARGINWIDTHN, 0)) Sci(_editor, SCI_SETMARGINWIDTHN, 0, width);
}

- (void)scheduleChange:(BOOL)change update:(BOOL)update {
    _pendingChange |= change;
    _pendingUpdate |= update;
    if (_callbacksScheduled) return;
    _callbacksScheduled = YES;
    __weak LMEditorView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        LMEditorView *view = weakSelf;
        if (!view) return;
        const BOOL changed = view->_pendingChange;
        const BOOL updated = view->_pendingUpdate;
        view->_pendingChange = view->_pendingUpdate = view->_callbacksScheduled = NO;
        if (changed) [view updateLineNumberWidth];
        if (changed && view.onChange) view.onChange();
        if (updated && view.onUpdate) view.onUpdate();
    });
}

- (void)notification:(SCNotification *)notification {
    switch (notification->nmhdr.code) {
        case SCN_MODIFIED:
            if (notification->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) {
                _lastSearchQuery = nil;
                _lastSearchPosition = -1;
                [self scheduleChange:YES update:YES];
            }
            break;
        case SCN_SAVEPOINTLEFT:
        case SCN_SAVEPOINTREACHED:
        case SCN_FOCUSIN:
        case SCN_FOCUSOUT:
            [self scheduleChange:NO update:YES];
            break;
        case SCN_UPDATEUI:
            if (notification->updated & (SC_UPDATE_CONTENT | SC_UPDATE_SELECTION)) [self updateBraces];
            [self scheduleChange:NO update:YES];
            break;
        case SCN_ZOOM:
            [self updateLineNumberWidth];
            [self scheduleChange:NO update:YES];
            break;
        case SCN_CHARADDED:
            if (notification->ch == '\n' ||
                (notification->ch == '\r' && Sci(_editor, SCI_GETEOLMODE) == SC_EOL_CR)) [self autoIndent];
            break;
        default: break;
    }
}

- (void)updateBraces {
    NSInteger brace = -1;
    const NSInteger caret = Sci(_editor, SCI_GETCURRENTPOS);
    const NSInteger length = Sci(_editor, SCI_GETLENGTH);
    for (NSInteger position : {caret - 1, caret}) {
        if (position < 0 || position >= length) continue;
        const int ch = static_cast<int>(Sci(_editor, SCI_GETCHARAT, position));
        if (ch && std::strchr("[](){}", ch)) { brace = position; break; }
    }
    const NSInteger other = brace >= 0 ? Sci(_editor, SCI_BRACEMATCH, brace) : -1;
    if (brace >= 0 && other < 0) {
        Sci(_editor, SCI_BRACEHIGHLIGHT, -1, -1);
        Sci(_editor, SCI_BRACEBADLIGHT, brace);
    } else {
        Sci(_editor, SCI_BRACEBADLIGHT, -1);
        Sci(_editor, SCI_BRACEHIGHLIGHT, brace, other);
    }
}

- (void)autoIndent {
    if (Sci(_editor, SCI_GETREADONLY)) return;
    // All selections have been updated before SCN_CHARADDED. Work bottom-up so
    // earlier insertion positions stay valid; repeated notifications are harmless.
    std::vector<std::pair<NSInteger, NSInteger>> selections;
    for (NSInteger i = 0; i < Sci(_editor, SCI_GETSELECTIONS); ++i)
        selections.emplace_back(Sci(_editor, SCI_GETSELECTIONNCARET, i), i);
    std::sort(selections.rbegin(), selections.rend());
    for (const auto &[caret, index] : selections) {
        const NSInteger line = Sci(_editor, SCI_LINEFROMPOSITION, caret);
        if (line <= 0 || caret != Sci(_editor, SCI_POSITIONFROMLINE, line)) continue;
        if (caret != Sci(_editor, SCI_GETSELECTIONNANCHOR, index)) continue;
        const NSInteger indent = Sci(_editor, SCI_GETLINEINDENTATION, line - 1);
        if (indent <= 0) continue;
        if (Sci(_editor, SCI_GETLINEINDENTPOSITION, line) == caret) {
            if (selections.size() == 1) {
                // INSERTTEXT coalesces with the just-typed newline. SETLINEINDENTATION
                // would open a separate undo group for a single caret.
                const NSInteger tabs = self.useTabs ? indent / self.tabWidth : 0;
                const NSInteger spaces = indent - tabs * self.tabWidth;
                const std::string whitespace = std::string(tabs, '\t') + std::string(spaces, ' ');
                Sci(_editor, SCI_INSERTTEXT, caret, Pointer(whitespace.c_str()));
            } else {
                // Native multiple-caret input already has an enclosing undo group.
                Sci(_editor, SCI_SETLINEINDENTATION, line, indent);
            }
        }
        const NSInteger position = Sci(_editor, SCI_GETLINEINDENTPOSITION, line);
        Sci(_editor, SCI_SETSELECTIONNCARET, index, position);
        Sci(_editor, SCI_SETSELECTIONNANCHOR, index, position);
    }
}

- (NSInteger)searchData:(NSData *)query start:(NSInteger)start end:(NSInteger)end flags:(NSInteger)flags {
    Sci(_editor, SCI_SETSTATUS, SC_STATUS_OK);
    Sci(_editor, SCI_SETSEARCHFLAGS, flags);
    Sci(_editor, SCI_SETTARGETRANGE, start, end);
    return Sci(_editor, SCI_SEARCHINTARGET, query.length, Pointer(query.bytes));
}

- (void)revealStart:(NSInteger)start end:(NSInteger)end backwards:(BOOL)backwards {
    Sci(_editor, SCI_ENSUREVISIBLE, Sci(_editor, SCI_LINEFROMPOSITION, start));
    Sci(_editor, SCI_ENSUREVISIBLE, Sci(_editor, SCI_LINEFROMPOSITION, end));
    Sci(_editor, SCI_SETSEL, backwards ? end : start, backwards ? start : end);
    Sci(_editor, SCI_SCROLLCARET);
    [self scheduleChange:NO update:YES];
}

- (BOOL)find:(NSString *)query backwards:(BOOL)backwards matchCase:(BOOL)matchCase
       regex:(BOOL)regex wholeWord:(BOOL)wholeWord {
    if (!query.length) return NO;
    NSData *data = [query dataUsingEncoding:NSUTF8StringEncoding];
    const NSInteger flags = SearchFlags(matchCase, regex, wholeWord);
    const NSInteger length = Sci(_editor, SCI_GETLENGTH);
    const NSInteger original = Sci(_editor, backwards ? SCI_GETSELECTIONSTART : SCI_GETSELECTIONEND);
    NSInteger start = original;
    BOOL skipFirstRange = NO;
    if (Sci(_editor, SCI_GETSELECTIONSTART) == Sci(_editor, SCI_GETSELECTIONEND) &&
        _lastSearchPosition == original && _lastSearchFlags == flags &&
        _lastSearchBackwards == backwards && [_lastSearchQuery isEqualToString:query]) {
        start = Sci(_editor, backwards ? SCI_POSITIONBEFORE : SCI_POSITIONAFTER, start);
        skipFirstRange = start == original;
    }
    NSInteger found = -1;
    Sci(_editor, SCI_SETSTATUS, SC_STATUS_OK);
    if (!skipFirstRange) found = [self searchData:data start:start end:backwards ? 0 : length flags:flags];
    if (Sci(_editor, SCI_GETSTATUS) != SC_STATUS_OK) return NO;
    if (found < 0) found = [self searchData:data start:backwards ? length : 0 end:original flags:flags];
    if (found < 0 || Sci(_editor, SCI_GETSTATUS) != SC_STATUS_OK) return NO;
    const NSInteger end = Sci(_editor, SCI_GETTARGETEND);
    [self revealStart:found end:end backwards:backwards];
    _lastSearchQuery = [query copy];
    _lastSearchFlags = flags;
    _lastSearchBackwards = backwards;
    _lastSearchPosition = found == end ? found : -1;
    return YES;
}

- (NSInteger)replace:(NSString *)query with:(NSString *)replacement all:(BOOL)all
           matchCase:(BOOL)matchCase regex:(BOOL)regex wholeWord:(BOOL)wholeWord {
    if (!query.length || Sci(_editor, SCI_GETREADONLY)) return 0;
    NSData *needle = [query dataUsingEncoding:NSUTF8StringEncoding];
    NSData *substitution = [replacement dataUsingEncoding:NSUTF8StringEncoding];
    const NSInteger flags = SearchFlags(matchCase, regex, wholeWord);
    NSInteger limit = Sci(_editor, SCI_GETLENGTH);
    const NSInteger selectionStart = Sci(_editor, SCI_GETSELECTIONSTART);
    const NSInteger selectionEnd = Sci(_editor, SCI_GETSELECTIONEND);
    NSInteger found = [self searchData:needle start:all ? 0 : selectionStart end:limit flags:flags];
    if (Sci(_editor, SCI_GETSTATUS) != SC_STATUS_OK) return -1;
    if (!all && !(found == selectionStart && Sci(_editor, SCI_GETTARGETEND) == selectionEnd)) {
        found = [self searchData:needle start:selectionEnd end:limit flags:flags];
        if (Sci(_editor, SCI_GETSTATUS) != SC_STATUS_OK) return -1;
        if (found < 0) found = [self searchData:needle start:0 end:selectionEnd flags:flags];
    }
    if (Sci(_editor, SCI_GETSTATUS) != SC_STATUS_OK) return -1;
    if (found < 0) return 0;
    NSInteger count = 0;
    Sci(_editor, SCI_BEGINUNDOACTION);
    @try {
        while (found >= 0) {
            const NSInteger end = Sci(_editor, SCI_GETTARGETEND);
            const BOOL empty = found == end;
            const BOOL atEnd = end == limit;
            // Capture the original next character's byte width before modifying text.
            // Never search our own insertion again for a zero-width match.
            const NSInteger advance = empty && !atEnd ? Sci(_editor, SCI_POSITIONAFTER, end) - end : 0;
            const NSInteger inserted = Sci(_editor, regex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET,
                                           substitution.length, Pointer(substitution.bytes ?: ""));
            if (inserted < 0 || Sci(_editor, SCI_GETSTATUS) != SC_STATUS_OK) return -1;
            ++count;
            limit += inserted - (end - found);
            const NSInteger next = found + inserted + advance;
            if (!all) {
                [self revealStart:next end:next backwards:NO];
                break;
            }
            if (empty && atEnd) break;
            found = [self searchData:needle start:next end:limit flags:flags];
            if (Sci(_editor, SCI_GETSTATUS) != SC_STATUS_OK) return -1;
        }
    } @finally {
        Sci(_editor, SCI_ENDUNDOACTION);
    }
    return count;
}

- (void)goToLine:(NSInteger)line {
    const NSInteger count = Sci(_editor, SCI_GETLINECOUNT);
    const NSInteger target = std::clamp(line, NSInteger(1), std::max<NSInteger>(1, count)) - 1;
    Sci(_editor, SCI_ENSUREVISIBLE, target);
    Sci(_editor, SCI_GOTOLINE, target);
    [self scheduleChange:NO update:YES];
}

- (void)toggleComment:(NSString *)prefix {
    if (!prefix.length || [prefix rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound ||
        Sci(_editor, SCI_GETREADONLY)) return;
    NSData *marker = [prefix dataUsingEncoding:NSUTF8StringEncoding];
    NSString *spacedPrefix = [NSCharacterSet.whitespaceCharacterSet characterIsMember:[prefix characterAtIndex:prefix.length - 1]]
                           ? prefix : [prefix stringByAppendingString:@" "];
    NSData *insertion = [spacedPrefix dataUsingEncoding:NSUTF8StringEncoding];
    std::set<NSInteger> lines;
    for (NSInteger i = 0; i < Sci(_editor, SCI_GETSELECTIONS); ++i) {
        const NSInteger start = Sci(_editor, SCI_GETSELECTIONNSTART, i);
        const NSInteger end = Sci(_editor, SCI_GETSELECTIONNEND, i);
        const NSInteger first = Sci(_editor, SCI_LINEFROMPOSITION, start);
        NSInteger last = Sci(_editor, SCI_LINEFROMPOSITION, end);
        if (end > start && end == Sci(_editor, SCI_POSITIONFROMLINE, last)) --last;
        for (NSInteger line = first; line <= last; ++line) lines.insert(line);
    }
    struct Line { NSInteger position; BOOL commented; NSInteger removeLength; };
    std::vector<Line> edits;
    BOOL allCommented = YES;
    for (NSInteger line : lines) {
        const NSInteger start = Sci(_editor, SCI_GETLINEINDENTPOSITION, line);
        const NSInteger end = Sci(_editor, SCI_GETLINEENDPOSITION, line);
        if (start == end && lines.size() > 1) continue;
        BOOL commented = end - start >= static_cast<NSInteger>(marker.length);
        for (NSUInteger i = 0; commented && i < marker.length; ++i)
            commented = Sci(_editor, SCI_GETCHARAT, start + i) == static_cast<const unsigned char *>(marker.bytes)[i];
        NSInteger removeLength = marker.length;
        if (commented && start + removeLength < end && Sci(_editor, SCI_GETCHARAT, start + removeLength) == ' ' &&
            ![prefix hasSuffix:@" "]) ++removeLength;
        allCommented &= commented;
        edits.push_back({start, commented, removeLength});
    }
    if (edits.empty()) return;
    Sci(_editor, SCI_BEGINUNDOACTION);
    @try {
        for (auto it = edits.rbegin(); it != edits.rend(); ++it) {
            Sci(_editor, SCI_SETTARGETRANGE, it->position, it->position + (allCommented ? it->removeLength : 0));
            Sci(_editor, SCI_REPLACETARGET, allCommented ? 0 : insertion.length,
                Pointer(allCommented ? "" : insertion.bytes));
        }
    } @finally {
        Sci(_editor, SCI_ENDUNDOACTION);
    }
}

@end
