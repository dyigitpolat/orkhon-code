# Orkhon Code

A small native macOS editor for text and source code. Scintilla handles editing, Lexilla provides syntax highlighting, and SwiftTerm supplies real terminals. There is no account, telemetry, language server, or extension marketplace.

## Build and install

Requires an Apple silicon Mac, macOS 13+, Xcode Command Line Tools with Swift 6+, and Python 3. All library sources are vendored: no package downloads or dependency manager setup.

```sh
# Once, if the command-line tools are not installed:
xcode-select --install

# Inside your clone of this repository:
make install
```

`make install` builds the app and opens **outputs/Orkhon Code Installer.pkg** in macOS Installer. Follow its normal installation prompts. Orkhon opens its welcome page automatically after installation. To build without opening Installer, run `make build` or `./scripts/build.sh`.

The first-launch screen lists recommended source-file defaults, selected initially. Deselect exceptions or keep every current default. Changes happen only after confirmation; previous handlers are recorded first. HTML, browser documents, media and ambiguous extensions are excluded. Markdown and C++ headers are included when their current app is a general-purpose editor. macOS shares C++ source defaults (.cpp/.cc/.cxx/.c++) with .cp; setup clearly includes this alias in the C++ group. Registering the app alone does not claim a default.

The source builds with a local ad-hoc signature. For public binary distribution, supply an Apple Developer ID identity through `ORKHON_SIGN_IDENTITY`, sign the installer with `ORKHON_INSTALLER_SIGN_IDENTITY`, and notarize it with Apple's tools. Source builds do not require a paid Apple developer account.

## Features

- 145 syntax profiles using established Lexilla lexers and upstream SciTE configuration.
- Multiple independent windows; move tabs between windows without losing undo history.
- Two editor panes: drag a tab to the left or right of the editor, or use its context menu.
- Search and replace, regular expressions, multiple selections, comments, indentation, wrapping, encoding support, and recovery snapshots.
- Native Markdown reading and WebKit HTML previews, with persistent Source / Preview / Side by side controls. Live previews debounce edits for 250 ms with a one-second maximum scheduling delay.
- A lazy file tree that follows the common parent of open files. Explicitly opening a folder locks the workspace root. Open documents are marked and their ancestor paths expand.
- Independent terminal tabs, started only when requested. Document and terminal tabs have unobtrusive scroll tracks beneath them.
- SSH workspaces using the system configuration and key agent, native password/passphrase and server-verification prompts, then a remote directory browser.
- External file monitoring, automatic clean-file reloads, automatic merging of independent external edits to dirty files, and compact inline controls for overlapping conflicts. Added lines are green; removed lines remain as red read-only annotations until saving.
- Four coordinated themes: Obsidian, Daylight, Dusk, and Paper.

HTML preview executes the page's JavaScript and may load its network resources, like opening a local page in a browser. It uses an isolated, nonpersistent WebKit data store, no native script bridge, and file-origin access so relative local resources resolve. WebKit is not instantiated for text editing or Markdown.

See [the user guide](Resources/User%20Guide.md) for shortcuts and behavior.

## Architecture and extensions

`ApplicationCoordinator` owns application lifetime and window sessions. Each `EditorWindowController` owns its documents, workspace, terminal and two `EditorPane` hosts. An `EditorPane` binds a document's existing Scintilla view to a source/preview deck. Moving a document transfers that view and rewires its callbacks, preserving the buffer, selections and undo stack.

| Boundary | Responsibility |
| --- | --- |
| `Sources/EditorBridge` | Objective-C++ Scintilla/Lexilla adapter; no handwritten syntax parser |
| `Sources/LumenCore` | Encoding, conflict-aware atomic storage, OS diff engine and structured three-way merge |
| `Sources/Lumen/DocumentPreview.swift` | Lazy WebKit, native preview layout and bounded debounce |
| `Sources/Lumen/MarkdownView.swift` | Foundation CommonMark parsing off the UI thread; TextKit rendering |
| `Sources/Lumen/RemoteWorkspace.swift` | OpenSSH transport, quoting, bounded reads and optimistic saves |
| `Sources/SSHAskpass` | Small native authentication helper; no credential storage |
| `Sources/Lumen/FileTreePanel.swift` | Async directory enumeration and filesystem actions |
| `Sources/Lumen/TerminalPanel.swift` | Native SwiftTerm views, PTYs and process lifecycle |
| `Sources/Lumen/AssociationPolicy.swift` | Reviewed source-type catalog, kept separate from syntax coverage |

Add a command in the window controller's relevant extension, wire it in `Menus.swift`, and optionally expose it in `PaletteActions.swift`. Add themes in `Theme.swift`. Add language profiles through the upstream-property generator. Preview types belong behind `PreviewKind` and `EditorPane`, not in the editing engine. Internal Swift target names retain the development codename Lumen; the public bundle identifier is `app.orkhon.editor`. The existing `Orkhon Editor` application-support directory is retained so upgrades preserve recovery and association backups.

## Validation and performance

```sh
make verify
```

The full suite requires a logged-in macOS desktop because it tests real AppKit windows and PTYs. All document fixtures and recovery data are isolated under `work/` or private temporary directories. SSH transport tests run locally; they never connect to a server. CI builds the installer and exercises file-association policy, merging and local SSH operations. The workflow is included but has not run on a remote repository until you publish one.

`python3 scripts/benchmark.py` accepts the app's executable path and measures fresh processes with warm filesystem caches. Readiness includes window construction and synchronous AppKit drawing; it does not measure compositor presentation or Finder dispatch. Preview and terminal processes start only on demand. A universal sub-100 ms launch guarantee is not established; compare measured distributions on the target machine.

The storage limit is 256 MB, remote files 32 MB, Markdown preview 5 MB, HTML live preview 10 MB, and automatic merge inputs 8 MB each. Larger merge conflicts retain the working buffer and offer Save As for a separate copy. Recovery is best effort, approximately 0.8 seconds after editing. Concurrent writes from unrelated applications can still race an optimistic save.

## License and dependencies

Orkhon source is MIT licensed. Upstream license files remain in each vendor directory and are bundled with the app. Versions and immutable source references are listed in [Vendor/DEPENDENCIES.md](Vendor/DEPENDENCIES.md).

The project does not bundle credentials, signing keys, local preference backups, generated binaries, or user documents. No remote repository is configured by the local build.
