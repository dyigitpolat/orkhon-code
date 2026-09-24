# Install Orkhon Code

## From a release

1. Download **Orkhon.Code.Installer.pkg** from [Releases](https://github.com/dyigitpolat/orkhon-code/releases).
2. Quit any running copy of Orkhon Code, then open the package and follow macOS Installer.
3. Orkhon opens the welcome page. In **File Defaults**, search or scroll through the selected text and source formats. Uncheck any exceptions, then apply your choices. **Keep all current defaults** leaves them unchanged.

The published package is locally signed, not Apple-notarized. macOS may block a downloaded package. If you trust this repository and have verified the download, use **System Settings → Privacy & Security → Open Anyway** after attempting to open it. Do not disable Gatekeeper globally. Building from source below avoids relying on a downloaded binary.

## Build and install from source

You need an **Apple silicon Mac**, **macOS 13 or later**, **Swift 6 or later** (Xcode 16 / matching Command Line Tools), and **Python 3**. Intel Macs, Windows, and Linux are not currently supported.

### 1. Install Apple's build tools

Open Terminal and run:

```sh
xcode-select --install
```

Follow Apple's installer. If the tools are already installed, continue. Check the compiler and Python:

```sh
swift --version
python3 --version
```

If Swift is older than 6, update Xcode or its Command Line Tools. If Python is missing, install Python 3 from [python.org](https://www.python.org/downloads/macos/).

### 2. Get the source

```sh
git clone https://github.com/dyigitpolat/orkhon-code.git
cd orkhon-code
```

You can instead download the source ZIP from a release, extract it in Finder, and open Terminal in the extracted folder.

### 3. Build and open the installer

```sh
make install
```

That is the complete build command. It compiles the native editing and terminal engines, generates icons, creates the app, and opens the package in macOS Installer. All runtime dependencies are included in the repository. **No Homebrew, Node.js, npm, Swift package downloads, account, or paid developer membership is required.** Compilation takes longer than launching the finished app; allow several minutes for the first build.

If you prefer to build now and install later:

```sh
make build
open "outputs/Orkhon Code Installer.pkg"
```

Installation requires the normal macOS administrator prompt to place the app in `/Applications`. The build itself does not request administrator privileges, change file defaults, or install anything.

## File defaults

The catalog covers 181 reviewed text and source extensions, including `.txt`, `.json`, `.jsonc`, `.toml`, `.yaml`, `.md`, `.rs`, `.go`, `.cpp`, and `.hpp`. The visible choices reflect the file types registered on your Mac. Extensions sharing a macOS type appear in one row; selecting that row changes the whole group.

Formats are grouped by their current app, with its icon and a three-state group switch: **All**, **Selective**, or **Off**. Unchecking an individual format marks its group Selective; the group switch selects all eligible formats or turns them off. Eligible formats are selected initially. Use search to find an extension or its current app, then uncheck exceptions. The editor records previous defaults **before** applying changes and verifies each result. You can reopen this screen from **Orkhon Code → File Defaults**. Upgrading from an older release presents the expanded setup once.

HTML, SVG, browser shortcuts, media, and ambiguous binary formats are not claimed. Eligibility depends on the reviewed text format, **not its current application**. Ordinary `.log` files in Console, `.csv`/`.tsv` files in Numbers, text in TextEdit, and supported source files in any other app are selectable. The current app is shown so you can uncheck exceptions before confirming. Native Numbers spreadsheets and Console diagnostic archives remain excluded. `.ts` and `.mts` can mean video; use **Open File** for TypeScript files with those suffixes without replacing video defaults. `.tsx` and `.cts` are included. C++ source files share a macOS setting with `.cp`; the setup explicitly shows that alias.

Registration adds Orkhon to **Open With**; it does not itself make Orkhon the default. You do not need Full Disk Access or Accessibility permission to change defaults. If macOS rejects a choice, setup explains the failure and leaves the controls editable. You can adjust the selection and retry; successful changes and your opt-outs are retained. macOS presents any required consent prompt itself.

**macOS 26.4 and later requires a separate system approval for each changed file type.** Orkhon shows the number before starting (extensions that share a type count once), then progress through the requests. Use **Stop after current request** to end the queue after answering the current system dialog. Choosing **Keep** preserves the current app for that file type and continues with the remaining types. Only **Stop after current request** or an actual failure stops the queue. Completed changes stay applied; the remaining formats stay available to review and resume. You can continue to the editor at any point outside an active system request. Already-associated types are skipped.

Apple provides no public API to approve every type in one dialog. This is an operating-system limitation; installing Orkhon does not disable or auto-click system consent, rewrite Launch Services preferences, or require Accessibility permission. On older macOS versions, the same reviewed selection generally applies without per-type dialogs. See the [utiluti maintainer's investigation of the macOS 26.4 change](https://scriptingosx.com/2026/03/macos-26-4-brings-more-default-app-confirmation-prompts/).

## Updating

Quit Orkhon, get the new source, and rebuild:

```sh
git pull --ff-only
make install
```

The installer refuses to replace a running copy. Sessions, recovery files, and previous-default records remain in `~/Library/Application Support/Orkhon Editor/`; this historical folder name is intentional. Back it up before changing builds if you have unsaved recovery data.

## Uninstalling

Quit Orkhon, then move **Orkhon Code.app** from Applications to Trash. macOS normally selects another available app for its documents. To choose a specific replacement, select a file in Finder, open **Get Info → Open with**, select the app, and click **Change All**.

Recorded previous applications are in `File Associations.json` in the support folder above; installation-time observations are in `Installation Defaults.json`. Removing the app is not a guarantee that every historical default will be restored automatically. Do not delete this support folder until you have recovered unsaved documents and recorded any defaults you want to restore.

## Troubleshooting

| Problem | What to do |
| --- | --- |
| `xcrun` or a developer-directory error | Finish installing Command Line Tools. If Xcode is installed, select it in **Xcode → Settings → Locations → Command Line Tools**. |
| Swift compiler is too old | Install Xcode 16 or newer / matching Command Line Tools. Check `swift --version` again. |
| `make install` says Apple silicon is required | The current build supports `arm64` Macs only. |
| Installer asks you to quit Orkhon | Quit all Orkhon windows with **Command-Q**, then run the package again. |
| Build seems slow the first time | The native libraries compile locally. Later builds reuse unchanged objects. |
| A preview fails | Switch to Source; your editable buffer is preserved. Markdown preview is limited to 5 MB and individual diagrams to 50 KB. |
| A file type is protected | macOS maps it to a non-text or ambiguous format outside the reviewed catalog. Its current app never causes a lock. Open it from Orkhon without changing that default. |

For build failures, open an issue with your macOS version, `swift --version`, and the final error output. Avoid attaching personal files or credentials.
