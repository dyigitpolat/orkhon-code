#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Main-thread-only AppKit editor. Scintilla types stay private to the bridge.
@interface LMEditorView : NSView

/// Coalesced on the main queue, after editing/selection notifications have settled.
/// Capture the owner weakly when the owner also retains the editor.
@property(nonatomic, copy, nullable) void (^onChange)(void);
@property(nonatomic, copy, nullable) void (^onUpdate)(void);

/// Assigning text loads a document: clears undo history and establishes a save point.
@property(nonatomic, copy) NSString *text;
@property(nonatomic, readonly) BOOL modified;
/// One-based line and display column; tabs expand to tabWidth columns.
@property(nonatomic, readonly) NSInteger currentLine;
@property(nonatomic, readonly) NSInteger currentColumn;
/// Unicode character count across all selections (not UTF-8 byte length).
@property(nonatomic, readonly) NSInteger selectionLength;
@property(nonatomic) BOOL wordWrap;
@property(nonatomic) BOOL showWhitespace;
@property(nonatomic) NSInteger tabWidth;
@property(nonatomic) BOOL useTabs;
/// Base font size in points; native Scintilla zoom is independent.
@property(nonatomic) CGFloat fontSize;

- (void)markSaved;
/// Replaces the primary selection as an undoable edit, preserving the save point.
- (void)insertRecoveredText:(NSString *)text NS_SWIFT_NAME(insertRecoveredText(_:));
- (void)focus;
- (void)command:(NSInteger)message;
/// Raw Scintilla messages use its native UTF-8 byte positions and pointer-sized values.
- (NSInteger)send:(NSInteger)message w:(NSInteger)w l:(NSInteger)l;

/// Names come from availableLexers. Unknown/empty names select plain text.
/// Keyword arrays are zero-based Lexilla word lists; properties replace the previous set.
/// Initial coloring is bounded; Scintilla styles to the viewport during native idle work.
- (void)setLexer:(NSString *)name
        keywords:(NSArray<NSString *> *)keywords
      properties:(NSDictionary<NSString *, NSString *> *)properties NS_SWIFT_NAME(setLexer(_:keywords:properties:));
/// Missing keys use defaults. Keys: background, foreground, muted, selection, line,
/// accent, keyword, string, number, comment, type, operator.
- (void)applyPalette:(NSDictionary<NSString *, NSColor *> *)palette NS_SWIFT_NAME(applyPalette(_:));

/// Searches wrap once. Empty queries and invalid regular expressions return NO.
/// Regex syntax is Scintilla's C++11 ECMAScript syntax.
- (BOOL)find:(NSString *)query
   backwards:(BOOL)backwards
   matchCase:(BOOL)matchCase
       regex:(BOOL)regex
   wholeWord:(BOOL)wholeWord NS_SWIFT_NAME(find(_:backwards:matchCase:regex:wholeWord:));
/// Replaces the matching selection, or the next match (wrapping once).
/// all=YES replaces throughout the document in one undo action.
/// Regex replacements support Scintilla backreferences: \0 through \9.
/// Returns the replacement count; -1 means search/replacement error (including invalid regex).
/// Empty queries and read-only documents return 0. Inspect SCI_GETSTATUS for error details.
- (NSInteger)replace:(NSString *)query
                with:(NSString *)replacement
                 all:(BOOL)all
           matchCase:(BOOL)matchCase
               regex:(BOOL)regex
           wholeWord:(BOOL)wholeWord NS_SWIFT_NAME(replace(_:with:all:matchCase:regex:wholeWord:));
/// One-based; out-of-range values are clamped to the document.
- (void)goToLine:(NSInteger)line NS_SWIFT_NAME(go(toLine:));
/// Toggles a literal line-comment prefix after indentation on selected lines.
/// A selection ending at the next line's start excludes that next line.
- (void)toggleComment:(NSString *)prefix NS_SWIFT_NAME(toggleComment(_:));
+ (NSArray<NSString *> *)availableLexers;

@end

NS_ASSUME_NONNULL_END
