# Orkhon Code

A compact native editor for macOS 13 and later. Built for Apple Silicon.

## Everyday work

- **⇧⌘N** opens a window; **⌥⌘O** opens files in a new window.
- **⌘N** creates a tab; **⌘O** opens files; **⇧⌘O** opens a folder.
- **⌘S** saves; **⇧⌘S** saves under a new name; **⌥⌘S** saves all edited tabs.
- **⌘W** closes the current tab. Unsaved changes require a save/discard decision.
- **⌘P** searches workspace filenames and paths. Without a folder, it searches open and recent files.
- **⇧⌘P** opens the command palette. Type a few letters, then press Return.
- **⌘F** or **Ctrl+F** opens Find and Replace; **⌘G / ⇧⌘G** advance between matches.
- Search supports case sensitivity, whole words, and C++11 ECMAScript regular expressions. Replacement backreferences use `\1` through `\9`.
- **⌘L** jumps to a line. **⌘D** adds the next matching occurrence to the selection.
- **⇧⌘D** duplicates a line or selection; **⌥↑ / ⌥↓** move selected lines.
- **⌘[ / ⌘]** outdent/indent. **⌘/** toggles a line comment for common language families.
- **⌥Z** toggles word wrap. **⌘+ / ⌘− / ⌘0** change/reset the font size.
- **⇧⌘[ / ⇧⌘]** switch tabs. **⌥⌘P** prints.

## Files and terminals

**⌘B** shows or hides the file tree. Drag the divider to resize it. The root follows the deepest common parent of all open local files until you explicitly choose a folder. Folders load when expanded. Context menus provide file/folder creation, renaming, Reveal in Finder, and Move to Trash. Symbolic-link folders are not traversed.

**⌃`** shows or hides the terminal. **⇧⌃`** expands it. The plus button creates an independent login shell; each tab has its own real pseudo-terminal. Terminals continue running while hidden. Closing a live terminal asks before ending its processes. New terminals start in the chosen workspace or the current file’s folder. Changing folders does not send commands to running shells.

No shell starts until the terminal is opened. No project scripts execute automatically.

Option-based symbols use your macOS keyboard layout, including brackets, angle brackets and accented characters. To send a Meta shortcut, press Escape followed by its key.

The bundled SwiftTerm version supports application-requested mouse clicks and drags, but does not forward scroll-wheel events to terminal applications. This affects scrolling inside tools such as Claude Code and tmux. Use the application's keyboard scrolling controls for now; ordinary terminal scrollback still works. This is a [known upstream limitation](https://github.com/migueldeicaza/SwiftTerm/issues/517), addressed by newer SwiftTerm releases that have not yet been adopted here.

Right-click a document tab for **Pin**, **Close Tab**, **Close Others**, or **Close to the Right**. Group closing preserves pinned tabs and asks about unsaved changes. Overflow arrows and the open-tabs list help navigate a long tab strip; selecting or opening a tab scrolls it into view.

## Previews, split editing and SSH

**Source / Preview / Side by side** stays visible above Markdown and HTML documents. **⇧⌘M** toggles preview. Live updates wait 250 ms after typing, with a one-second maximum scheduling delay. Filesystem changes anywhere in the workspace refresh previews after one second of quiet, with a three-second maximum scheduling delay during continuous changes. Every file type is included, including untracked and generated files. Hidden previews update when shown. A slow render or page load can take longer to finish. HTML uses native WebKit, resolves relative CSS/JavaScript against the document folder, and can load remote resources. The WebKit instance uses a nonpersistent data store. Only explicitly opening HTML preview runs its page scripts.

Drag a tab onto the left or right of the editor, or use **Split to the Left/Right** in its context menu, to open a second document pane. The thin pane headers show filenames. Close a pane to return to one editor; its tab stays open. Two document panes disable side-by-side preview and switch an existing side-by-side view to source. Either pane can still use a full preview. **Move to New Window** transfers the actual document and its undo history.

Markdown previews support tables with alignment, task lists, strikethrough, fenced code, links, relative images, safe HTML, KaTeX formulas and Mermaid diagrams. Use `$…$` for inline formulas, `$$…$$` for displayed formulas, and a fenced block labeled `mermaid` for diagrams. The renderer uses bundled markdown-it, DOMPurify, KaTeX and Mermaid, with no CDN downloads. WebKit starts only when you request a user-document preview; math and diagram libraries load only when needed. The built-in welcome page stays native. Files larger than 5 MB remain available in the source editor.

The network button beside **Open Folder** connects to an SSH-config alias or `user@hostname`. Choose a profile or enter a hostname, with optional user and port. OpenSSH uses keys and its agent first; a secure native prompt requests a password or passphrase when needed and asks before trusting a new server. After connection, choose a remote folder. Passwords are not stored. The file tree browses that server, files open in normal tabs, and new terminal tabs connect to it. Existing local terminals remain local. Disconnect closes remote tabs after save/discard prompts.

SSH uses the system OpenSSH client, configuration, and key agent. Servers need a POSIX shell and standard file utilities; safe remote saving also needs `sha256sum`, `shasum`, or `sha256`. Remote files are limited to 32 MB. Symbolic links are shown but not edited. Saves preserve permissions and open the same change review used for local files when the server changed. Linux and macOS servers with Python 3 stream filesystem events through a persistent SSH channel. The helper is sent in memory, installs nothing, and exits when the channel closes. Events update open files, expanded folders and visible previews; relative Markdown images and HTML CSS/JavaScript load on demand over SSH. Checksums reconcile open files after events, catching edits with unchanged size and modification time. Only changed document contents are downloaded. If the event channel is unavailable, the sidebar reports ten-second reconciliation while the connection retries. Network filesystems that do not report changes from other machines may still need a manual refresh. Remote files are saved only when you request it. Remote sessions do not reconnect automatically after relaunch; unsaved recovery text is restored as a local untitled document.

## Appearance and editing

Choose **Obsidian**, **Daylight**, **Dusk**, or **Paper** in the top bar or View → Theme. Font size, indentation, tabs/spaces, and wrapping are available in View. Appearance and editing preferences persist across launches.

Language detection uses filenames, extensions, and shebangs. The language selector at the bottom permits an explicit choice. Highlighting and folding come from Lexilla. Some language profiles, including Swift and Kotlin, use compatible lexers with language-specific keywords; they are lexical highlighting, not compiler-level semantic analysis.

## Keeping your text safe

UTF-8 and BOM-marked UTF-16/UTF-32 retain their encoding and byte-order mark. Existing newlines are preserved; newly inserted lines follow the detected convention. Files with binary control data are rejected. Invalid Unicode is rejected rather than silently replacing characters. **File → Open with Encoding** provides explicit Windows-1252, ISO Latin-1, Shift JIS, and Mac Roman fallback choices for older files. The current document limit is 256 MB.

Saves replace files atomically and preserve POSIX permissions. Filesystem notifications detect changes made by another app, including atomic replacements. Clean buffers update automatically. When you have unsaved changes, independent external edits merge immediately. Added lines use a subtle green background; removed lines stay visible as red read-only annotations. Only overlapping edits need a decision: your current span has stronger red emphasis, and the incoming replacement appears below it in green. A bordered **Conflict** toolbar separates these versions, with flat **Keep current**, **Use incoming**, and **Keep both** actions. The source remains editable. Each action resolves one span immediately; **Next conflict** moves to the next unresolved span. Accepted change highlights remain until saving. Controls follow scrolling and divider resizing, and offscreen controls are created only when needed. Choices are undoable and do not save until you request it. Saving pauses for unresolved conflicts. Automatic merge is bounded to 8 MB per input. **Save As** can preserve an independent copy. Changes are also checked before saving. Saving is optimistic: an unrelated program writing during the final replacement can still race a save.

Unsaved recovery snapshots are written about 0.8 seconds after editing to `~/Library/Application Support/Orkhon Editor/Recovery`, with private file permissions. Recovery is best effort; edits within that interval can be lost after a sudden crash or power failure. Save important changes with ⌘S. Recovery snapshots and previously open files are restored on the next launch.

Large file reads and folder enumeration run away from the main interface. Quick Open scans only on demand, skips common generated folders, and caps its list at 20,000 files. There is no background language server, extension marketplace, telemetry, updater, or account requirement.

## About this build

Native AppKit UI; Scintilla editor; Lexilla syntax highlighting; SciTE language configuration; SwiftTerm terminal. Component licenses are bundled under `Contents/Resources/Licenses`.

This is a locally built and ad-hoc signed app. Developer ID signing and Apple notarization require a distribution identity and are not included in this local installation.

## First launch and default apps

Installation adds Orkhon Code to Applications and opens its welcome page automatically. Recommended text and source-file groups start selected. Formats are grouped by their current app. Each group switch shows **All**, **Selective**, or **Off**. Unchecking one format changes its group to Selective; clicking the group switch selects all eligible formats or turns the group off. Search by extension or app. Deselect any exceptions, then choose “Apply defaults and start editing.” Each group shows its current or recorded previous app. Markdown, C++ source, and C++ headers are eligible. macOS shares C++ source defaults with .cp, which is shown explicitly in that group. “Keep all current defaults” starts editing without changing associations. Revisit the screen through Orkhon Code → File Defaults.

The catalog covers 181 reviewed text and code extensions, including .txt, .json, .jsonc, .toml, .yaml, .rs, and .go. Browser documents (including HTML), images and design files, media, and ambiguous extensions keep their current apps. You can still open supported text manually and use its syntax highlighting.

Click the language name at the bottom right to search by language or extension. Use arrows and Return, or click a result. Automatic restores filename/shebang detection; Escape dismisses the panel.
