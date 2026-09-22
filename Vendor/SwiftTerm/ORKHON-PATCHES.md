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
