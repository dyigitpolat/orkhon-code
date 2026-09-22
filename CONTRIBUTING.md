# Contributing

Start with `make build`. The dependencies are vendored so the first build works without dependency downloads. Keep UI work on the main actor, filesystem and remote operations off it, and parser work bounded. Preserve undo history when moving documents or applying external edits.

Run `make verify` in a logged-in macOS desktop session before proposing behavior changes. Add focused regression coverage for data loss, file conflicts, process lifecycle and cross-window state. Avoid tests that only restate view construction. Keep launch measurements comparable: release builds, fresh processes, the same filesystem-cache conditions, and no preview/terminal process unless requested.

Never replace or re-sign a running app bundle. Packaging always creates a fresh immutable staging directory, and macOS Installer handles installed-app replacement. Do not change file defaults during build or launch; use the reviewed first-launch consent flow. Keep ambiguous extensions and specialist handlers protected.

Describe the concrete problem, final behavior, tests and any remaining limits in pull requests. Keep unrelated generated outputs and local user data out of commits. See the MIT license and upstream dependency license files before changing vendored code.
