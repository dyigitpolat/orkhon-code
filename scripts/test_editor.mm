#import "EditorBridge.h"
#import "Scintilla.h"
#import "ScintillaView.h"
#include <cstdio>
#include <cstdlib>
static int passed = 0;
static void check(bool ok, const char *message) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
    ++passed;
}
static NSInteger s(LMEditorView *e, NSInteger m, NSInteger w=0, NSInteger l=0) { return [e send:m w:w l:l]; }
static NSInteger replace(LMEditorView *e, NSString *q, NSString *r, BOOL regex=YES, BOOL all=YES) {
 return [e replace:q with:r all:all matchCase:YES regex:regex wholeWord:NO];
}
static BOOL find(LMEditorView *e, NSString *q, BOOL back=NO, BOOL regex=NO) {
 return [e find:q backwards:back matchCase:YES regex:regex wholeWord:NO];
}
int main() { @autoreleasepool {
 [NSApplication sharedApplication];
 LMEditorView *e = [[LMEditorView alloc] initWithFrame:NSMakeRect(0,0,800,600)];
 // An unshown host window supplies a real viewport for styling/scrolling checks.
 NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,600)
     styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
 window.contentView=e;
 e.wordWrap=NO;e.text=@"short\nsecond\n";
 for (CGFloat width : {400.0, 1000.0, 650.0}) {
     [window setContentSize:NSMakeSize(width,600)];[e layoutSubtreeIfNeeded];
     NSView *hit=[e hitTest:NSMakePoint(NSWidth(e.bounds)-30,NSHeight(e.bounds)-25)];
     check([hit isKindOfClass:SCIContentView.class],"far-right blank space remains a clickable editor canvas after resize");
 }
 [window setContentSize:NSMakeSize(800,600)];
 e.text=@"unchanged\n";
 NSString *annotation=@"removed 猫\nadded 😀\n";
 NSUInteger redBytes=[@"removed 猫\n" lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
 NSMutableData *annotationStyles=[NSMutableData dataWithLength:[annotation lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
 memset(annotationStyles.mutableBytes,251,redBytes);
 memset((char *)annotationStyles.mutableBytes+redBytes,250,annotationStyles.length-redBytes);
 [e setExternalAnnotation:annotation styles:annotationStyles atLine:0];
 NSMutableData *actualStyles=[NSMutableData dataWithLength:annotationStyles.length];
 s(e,SCI_ANNOTATIONGETSTYLES,0,(NSInteger)actualStyles.mutableBytes);
 check([actualStyles isEqual:annotationStyles],"Unicode additions and removals keep independent byte-aligned styles");
 check([e.text isEqual:@"unchanged\n"] && !e.modified,"read-only change annotations never enter the document");
 auto oldRed=s(e,SCI_STYLEGETBACK,251);
 [e applyPalette:@{@"background":NSColor.blackColor,@"foreground":NSColor.whiteColor}];
 check(s(e,SCI_STYLEGETBACK,250)!=s(e,SCI_STYLEGETBACK,251) && s(e,SCI_STYLEGETBACK,251)!=oldRed,"add/remove colors remain distinct after theme changes");
 e.tabWidth=4;
 [e setExternalAnnotation:@"\tcall(a,\tvalue)\n" atLine:0];
 char aligned[128]={0};s(e,SCI_ANNOTATIONGETTEXT,0,(NSInteger)aligned);
 check(strcmp(aligned,"    call(a, value)\n")==0,"annotation indentation shares source tab stops without added labels or prefixes");
 [e clearExternalAnnotations];
 check(s(e,SCI_ANNOTATIONGETLINES,0)==0,"clearing change history removes ghost rows");
 check([LMEditorView.availableLexers containsObject:@"cpp"], "available lexer list");
 check(s(e, SCI_GETMULTIPLESELECTION) && s(e, SCI_GETADDITIONALSELECTIONTYPING), "multiple selections enabled");
 e.text = @"hello";
 check(!e.modified && !s(e, SCI_CANUNDO), "document loading clean and undo empty");
 s(e, SCI_SELECTALL); [e insertRecoveredText:@"restored 😀"];
 check(e.modified && [e.text isEqual:@"restored 😀"], "recovery modifies with Unicode");
 [e command:SCI_UNDO];
 check(!e.modified && [e.text isEqual:@"hello"], "recovery undo preserves save point");
 const char bytes[] = {'a',0,'b'};
 e.text = [[NSString alloc] initWithBytes:bytes length:3 encoding:NSUTF8StringEncoding];
 check(e.text.length == 3 && s(e,SCI_GETLENGTH)==3, "embedded NUL text roundtrip");
 e.text = @"é😀\n\t猫";
 s(e,SCI_SETSEL,0,6);
 check(e.selectionLength == 2, "Unicode selection count");
 [e goToLine:2]; s(e,SCI_CHARRIGHT);
 check(e.currentLine==2 && e.currentColumn==5, "one-based display column expands tabs");
 [e goToLine:NSIntegerMax]; check(e.currentLine==2, "line clamps upper bound");
 [e goToLine:NSIntegerMin]; check(e.currentLine==1, "line clamps lower bound");
 e.fontSize=14.5; check(e.fontSize==14.5, "fractional font size");
 e.wordWrap=YES; e.showWhitespace=YES; e.tabWidth=2; e.useTabs=YES;
 check(e.wordWrap && e.showWhitespace && e.tabWidth==2 && e.useTabs, "settings roundtrip");
 e.tabWidth=4; e.useTabs=NO;
 e.text=@"foo12 bar34";
 check(replace(e,@"([a-z]+)([0-9]+)",@"\\2-\\1")==2 && [e.text isEqual:@"12-foo 34-bar"], "regex backreferences preserved");
 [e command:SCI_UNDO]; check([e.text isEqual:@"foo12 bar34"] && !e.modified, "replace all single undo and clean");
 check(replace(e,@"(",@"bad")==-1 && [e.text isEqual:@"foo12 bar34"] && !e.modified, "invalid regex no mutation");
 check(!find(e,@"[",NO,YES), "invalid regex find");
 check(find(e,@"bar"), "valid search after invalid regex resets status");
 e.text=@"é😀x";
 check(replace(e,@"(?=.)",@"|")==3 && [e.text isEqual:@"|é|😀|x"], "zero-width replacement progresses by Unicode character");
 e.text=@"abc";
 check(replace(e,@"(?=.)",@"")==3 && [e.text isEqual:@"abc"], "zero-width empty replacement terminates");
 check(replace(e,@"$",@"!")==1 && [e.text isEqual:@"abc!"], "zero-width EOF inserted only once");
 e.text=@"";
 check(replace(e,@"^",@"!")==1 && [e.text isEqual:@"!"], "zero-width empty document");
 e.text=@"aa bb aa";
 check(find(e,@"aa") && s(e,SCI_GETSELECTIONSTART)==0, "forward find");
 check(find(e,@"aa") && s(e,SCI_GETSELECTIONSTART)==6, "forward find next");
 check(find(e,@"aa") && s(e,SCI_GETSELECTIONSTART)==0, "forward find wrap");
 check(find(e,@"aa",YES) && s(e,SCI_GETSELECTIONSTART)==6, "backward find wrap");
 check(find(e,@"aa",YES) && s(e,SCI_GETSELECTIONSTART)==0, "backward find next");
 e.text=@"é😀x";
 check(find(e,@"(?=.)",NO,YES) && s(e,SCI_GETCURRENTPOS)==0, "zero-width find initial");
 check(find(e,@"(?=.)",NO,YES) && s(e,SCI_GETCURRENTPOS)==2, "zero-width find progresses UTF8");
 e.text=@"cat scatter Cat cat";
 check([e replace:@"cat" with:@"dog" all:YES matchCase:NO regex:NO wholeWord:YES]==3 && [e.text isEqual:@"dog scatter dog dog"], "case insensitive whole-word replace");
 e.text=@"one two one";
 check(find(e,@"one") && replace(e,@"one",@"three",NO,NO)==1 && [e.text isEqual:@"three two one"], "single replacement uses selected match");
 e.text=@"  a\n    b\nc\n";
 s(e,SCI_SETSEL,0,10); // End at c's start.
 [e toggleComment:@"//"];
 check([e.text isEqual:@"  // a\n    // b\nc\n"], "comment excludes line at selection end");
 [e toggleComment:@"//"];
 check([e.text isEqual:@"  a\n    b\nc\n"], "uncomment preserves indentation");
 [e command:SCI_UNDO]; check([e.text isEqual:@"  // a\n    // b\nc\n"], "toggle comment one undo action");
 e.text=@"  first"; s(e,SCI_GOTOPOS,s(e,SCI_GETLENGTH)); s(e,SCI_NEWLINE);
 check([e.text isEqual:@"  first\n  "], "autoindent newline");
 [e command:SCI_UNDO]; check([e.text isEqual:@"  first"], "autoindent and newline undo together");
 e.text=@"  a\r\n  b"; s(e,SCI_GOTOPOS,s(e,SCI_GETLENGTH)); s(e,SCI_NEWLINE);
 check([e.text isEqual:@"  a\r\n  b\r\n  "], "CRLF load and autoindent");
 e.text=@"  a\n    b"; s(e,SCI_SETSELECTION,3,3); s(e,SCI_ADDSELECTION,9,9); s(e,SCI_NEWLINE);
 check([e.text isEqual:@"  a\n  \n    b\n    "], "multiple caret autoindent");
 [e setLexer:@"cpp" keywords:@[@"int return"] properties:@{@"fold":@"1"}];
 e.text=@"int f() {\n // c\n return 42;\n}\n";
 s(e,SCI_COLOURISE,0,-1);
 check((s(e,SCI_GETFOLDLEVEL,0) & SC_FOLDLEVELHEADERFLAG)!=0, "lexer folding levels");
 [e applyPalette:@{@"keyword":NSColor.redColor,@"comment":NSColor.greenColor}];
 check(s(e,SCI_STYLEGETFORE,5)==255 && s(e,SCI_STYLEGETFORE,1)==65280, "metadata keyword and comment palette");
 check(e.fontSize==14.5, "palette preserves font");
 s(e,SCI_TOGGLEFOLD,0);
 check(!s(e,SCI_GETLINEVISIBLE,1), "fold collapses before lexer change");
 [e setLexer:@"python" keywords:@[@"def return"] properties:@{}];
 check(s(e,SCI_GETALLLINESVISIBLE) && s(e,SCI_GETFOLDEXPANDED,0), "lexer change resets hidden lines and fold expansion");
 [e setLexer:@"cpp" keywords:@[@"int return"] properties:@{@"fold":@"1"}];
 s(e,SCI_COLOURISE,0,-1); // Explicit full styling is only for this tiny fixture.
 check((s(e,SCI_GETFOLDLEVEL,0) & SC_FOLDLEVELHEADERFLAG)!=0, "repeated lexer changes rebuild folding");
 s(e,SCI_TOGGLEFOLD,0);
 check(!s(e,SCI_GETLINEVISIBLE,1), "folding remains functional after repeated lexer changes");
 [e setLexer:@"missing-lexer" keywords:@[] properties:@{}];
 check(s(e,SCI_GETLEXER)==1, "unknown lexer falls back to null lexer");
 // Legacy lexers have tokens but often no runtime named-style metadata.
 for (NSString *lexer in @[@"toml",@"markdown"]) {
     [e setLexer:lexer keywords:@[] properties:@{}];
     [e applyPalette:@{@"foreground":NSColor.whiteColor,@"keyword":NSColor.redColor,@"accent":NSColor.blueColor,@"string":NSColor.greenColor}];
     e.text=[lexer isEqual:@"toml"] ? @"[table]\nkey = \"value\"\n" : @"# Heading\n**bold** and `code`\n";
     s(e,SCI_COLOURISE,0,-1);bool coloured=false;
     for (NSInteger pos=0;pos<s(e,SCI_GETLENGTH);++pos) if (s(e,SCI_STYLEGETFORE,s(e,SCI_GETSTYLEAT,pos)) != s(e,SCI_STYLEGETFORE,STYLE_DEFAULT)) coloured=true;
     check(coloured,"legacy lexer tokens have visible theme colors");
 }
 [e setLexer:@"null" keywords:@[] properties:@{}];e.text=@"alpha selected omega\nsecond row\n";
 [e applyPalette:@{@"background":NSColor.blackColor,@"foreground":NSColor.whiteColor,@"selection":NSColor.blueColor,@"line":NSColor.greenColor}];
 s(e,SCI_SETSEL,6,14);
 NSBitmapImageRep *selectionBitmap=[e bitmapImageRepForCachingDisplayInRect:e.bounds];
 [e cacheDisplayInRect:e.bounds toBitmapImageRep:selectionBitmap];
 NSInteger bluePixels=0;
 for (NSInteger y=0;y<selectionBitmap.pixelsHigh;++y) for (NSInteger x=0;x<MIN(600,selectionBitmap.pixelsWide);++x) {
     NSColor *pixel=[[selectionBitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
     if (pixel.blueComponent>0.5 && pixel.blueComponent>pixel.redComponent+0.3 && pixel.blueComponent>pixel.greenComponent+0.3) ++bluePixels;
 }
 [[selectionBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"work/selection-regression.png" atomically:YES];
 fprintf(stderr,"Selection blue pixels: %ld\n",(long)bluePixels);
 check(bluePixels>20,"single-row selection visibly draws over caret-line background");
 // An 8 MiB fixture catches eager full-document coloring without requiring a
 // 250 MB allocation/parse in the routine release suite. Assert work done, not
 // a machine-dependent timing threshold. No full COLOURISE on large fixtures.
 e.wordWrap=NO;
 NSString *largeText=[@"" stringByPaddingToLength:8*1024*1024
                                    withString:@"int sample() { return 42; }\n" startingAtIndex:0];
 e.text=largeText;
 [e setLexer:@"cpp" keywords:@[@"int return"] properties:@{@"fold":@"1"}];
 check(s(e,SCI_GETIDLESTYLING)==SC_IDLESTYLING_TOVISIBLE, "native idle styling is limited to visible text");
 const NSInteger firstViewportEnd=s(e,SCI_POSITIONFROMLINE,
     s(e,SCI_DOCLINEFROMVISIBLE,s(e,SCI_GETFIRSTVISIBLELINE)+MAX(1,s(e,SCI_LINESONSCREEN))+1));
 check(s(e,SCI_GETENDSTYLED)>0 && s(e,SCI_GETENDSTYLED)<=firstViewportEnd &&
       s(e,SCI_GETENDSTYLED)<=64*1024 && s(e,SCI_GETSTYLEINDEXAT,0)==5,
       "large file initially styles only viewport with keywords");
 check(s(e,SCI_GETSTYLEINDEXAT,7*1024*1024)==0 && !e.modified,
       "large file tail stays unstyled and clean");
 // Render the scrolled viewport offscreen. Only native painting/idle work may
 // advance styling here; an explicit COLOURISE would conceal a stalled frontier.
 s(e,SCI_SETFIRSTVISIBLELINE,5000);
 const NSInteger scrollTarget=s(e,SCI_POSITIONFROMLINE,5001);
 NSBitmapImageRep *bitmap=[e bitmapImageRepForCachingDisplayInRect:e.bounds];
 [e cacheDisplayInRect:e.bounds toBitmapImageRep:bitmap];
 NSDate *styleDeadline=[NSDate dateWithTimeIntervalSinceNow:2];
 while (s(e,SCI_GETENDSTYLED)<scrollTarget && styleDeadline.timeIntervalSinceNow>0) {
     [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
 }
 check(s(e,SCI_GETENDSTYLED)>=scrollTarget && s(e,SCI_GETENDSTYLED)<s(e,SCI_GETLENGTH) &&
       s(e,SCI_GETSTYLEINDEXAT,s(e,SCI_POSITIONFROMLINE,5000))==5,
       "native painting and idle work color newly scrolled text without styling EOF");
 s(e,SCI_SETFIRSTVISIBLELINE,s(e,SCI_GETLINECOUNT)/2);
 check(s(e,SCI_GETFIRSTVISIBLELINE)>1000, "large file fixture scrolls far from start");
 [e setLexer:@"cpp" keywords:@[@"int return"] properties:@{@"fold":@"1"}];
 check(s(e,SCI_GETENDSTYLED)>0 && s(e,SCI_GETENDSTYLED)<=64*1024,
       "lexer switch far down document bounds synchronous prefix styling");
 [e setLexer:@"missing-lexer" keywords:@[] properties:@{}];
 check(s(e,SCI_GETENDSTYLED)<=64*1024 && s(e,SCI_GETALLLINESVISIBLE),
       "large file plain-text switch stays bounded and clears folds");
 e.text=[@"//" stringByPaddingToLength:2*1024*1024 withString:@"x" startingAtIndex:0];
 [e setLexer:@"cpp" keywords:@[@"int return"] properties:@{}];
 check(s(e,SCI_GETENDSTYLED)>0 && s(e,SCI_GETENDSTYLED)<=64*1024,
       "single huge line cannot force full synchronous initial styling");
 __block NSInteger changes=0, updates=0;
 e.onChange=^{++changes;}; e.onUpdate=^{++updates;};
 e.text=@"notifications"; s(e,SCI_SELECTALL); [e insertRecoveredText:@"changed"];
 NSDate *until=[NSDate dateWithTimeIntervalSinceNow:0.1];
 while ([until timeIntervalSinceNow]>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
 check(changes==1 && updates>=1, "callbacks coalesced and delivered");
 e.onChange=nil; e.onUpdate=nil;
 printf("PASS: %d editor bridge checks\n", passed);
 return 0;
}}
