# Welcome to Orkhon Code

A fast, focused editor for text and source code.

## Start with a file

Use **Open File** or press **⌘O**. Open a folder with **⇧⌘O** to explore a project. The file tree follows your open files until you choose a folder yourself.

## Keep editing simple

- **⌘F** or **Ctrl+F** opens Find and Replace.
- **⌘P** quickly opens a workspace file.
- **⇧⌘P** opens the command palette.
- **⌘B** toggles the file tree.
- **Ctrl+`** opens the terminal.
- **⇧⌘N** opens another window. Right-click a tab to move it to a new window.
- Drag a tab onto the left or right of the editor to work in two panes.
- Right-click a tab to pin it or close a group of tabs.

## Choose your view

Use the theme selector for **Obsidian**, **Daylight**, **Dusk**, or **Paper**. Click the language name in the bottom-right corner to search syntax modes.

Markdown and HTML have a persistent **Source / Preview / Side by side** toolbar. Previews update as you edit. With two document panes open, each pane can show source or preview. Markdown supports tables, task lists, formulas and Mermaid diagrams. Renderers load only when needed; this welcome page stays native.

## Connect to a server

The network button beside **Open Folder** opens an SSH workspace. Use an SSH-config host alias or `user@hostname`. Sign in when prompted, then browse to a remote folder. Remote files open in normal tabs, and new terminals connect to that server.

## File defaults

The searchable setup screen includes common text and code formats such as **.txt**, **.json**, **.toml**, **.yaml**, **.md**, **.cpp**, and **.hpp**. Deselect anything you want to keep in its current app, then confirm. Browser, media, design, and ambiguous formats stay protected. You can revisit the choices in **Orkhon Code > File Defaults**.

Your files remain in their original locations. No account, telemetry, or background language server is required.

## Changes made elsewhere

Clean files refresh automatically. With unsaved edits, independent external changes merge automatically: added lines glow green and removed lines remain visible in red. Only overlapping changes need a decision. A compact **Conflict** toolbar sits between your current lines (red) and the incoming replacement (green). Choose **Keep current**, **Use incoming**, or **Keep both**. **Next conflict** jumps to the next unresolved span. This works for local and SSH files.
