# Orkhon compatibility patches

The base remains SwiftTerm v1.10.1 (`5c83a9d214e7354697624c11deb4e488bdcfabad`).
These small changes are intentionally recorded separately from our app settings.
Review and remove them when upgrading to an upstream release containing the fixes.

## macOS wheel reporting

`Mac/MacTerminalView.swift` forwards wheel events when an application enables
mouse reporting. This adapts the mouse-reporting portion of upstream commit
[`df2d4589`](https://github.com/migueldeicaza/SwiftTerm/commit/df2d4589e022c3cfe41019d27e05b8263d924d11)
for [issue #517](https://github.com/migueldeicaza/SwiftTerm/issues/517).
Coordinates are relative to the visible terminal, and the existing encoder
selects SGR, legacy X10, UTF-8, or other requested formats.

Precise trackpad deltas accumulate in pixels and emit whole cell-height steps,
following the approach in upstream v1.19.0. This avoids treating every tiny
trackpad event as a full wheel notch. The remainder resets on a new/cancelled
gesture and mouse-mode changes. Ordinary scrollback behavior is unchanged;
no arrow keys are synthesized into applications that do not request mouse input.

`Terminal.swift` clamps legacy X10 coordinates before converting to a byte.
Converting before clamping could otherwise trap on wide/tall terminal windows.

Validation: `scripts/test_terminal.sh` exercises native AppKit events, protocol
bytes, trackpad accumulation, mode changes, and real PTY delivery. No timer,
polling, or startup work is introduced by these patches.

## Hover and drag reporting

`Terminal.swift` adapts upstream [PR #520](https://github.com/migueldeicaza/SwiftTerm/pull/520):
SGR cell and pixel encodings inspect the motion bit before classifying a packet
as a release. No-button hover must remain code 35 with an uppercase `M`; the
old encoder changed it to code 32 with a lowercase `m`, which applications
could interpret as a button release and move their input cursor.

`Mac/MacTerminalView.swift` uses visible rows for hover coordinates, following
the mouse-coordinate portion of upstream [PR #590](https://github.com/migueldeicaza/SwiftTerm/pull/590).
It also honors `allowMouseReporting` for hover and the dedicated button-tracking
predicate for dragging in mode 1002, as current upstream does. The obsolete
SGR-pixel debug print is removed. Focus-reporting changes are not included.

Native regression checks cover hover versus click/release/drag, all modifier
combinations in cell/pixel formats, tracking opt-in, disabled reporting,
scrollback coordinates, and 1,000 consecutive hover events.

## Host keyboard bindings

`Mac/MacTerminalView.swift` exposes the existing `keyDown(with:)` override as
`open`, allowing Orkhon's `TerminalInputView` to implement its editing shortcuts.
The dependency's keyboard behavior is otherwise unchanged. Word-navigation and
deletion mappings live in the app's `TerminalPanel.swift`; ordinary Option text
still follows AppKit's keyboard-layout and input-method path.
