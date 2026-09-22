#!/bin/bash
# Requires macOS, Swift 6+ Command Line Tools, and a logged-in GUI session.
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'HELP'
Usage: scripts/test_filetree.sh [--trash]

Compile the current FileTreePanel with warnings as errors, then run its
filesystem, lazy-loading, AppKit, dialog, and mutation-callback checks.
Requires a logged-in macOS GUI session; run outside a GUI-restricted sandbox.

--trash also moves two UUID-named disposable fixtures to the real Trash, checks
their callbacks, and restores them before cleaning up the temporary fixtures.
It never enumerates, empties, or deletes the user's Trash. If interrupted during
these optional checks, a LumenFileTree-<UUID> fixture may remain in the Trash.

Build products and ordinary test fixtures use temporary directories. No app
sources are rewritten and no additional project dependencies are required.
HELP
    exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--trash" ) ]]; then
    printf 'Unexpected argument. Use --help for usage.\n' >&2
    exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'The native file tree checks require macOS.\n' >&2
    exit 2
fi

FILETREE_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FILETREE_TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/lumen-filetree-check.XXXXXX")"
trap 'rm -rf -- "$FILETREE_TEST_WORK"' EXIT

# Same-file access keeps private production implementation details private.
cat "$FILETREE_REPO_ROOT/Sources/Lumen/FileTreePanel.swift" \
    "$FILETREE_REPO_ROOT/scripts/test_filetree.swift" > "$FILETREE_TEST_WORK/Check.swift"
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
    -target "$(uname -m)-apple-macosx12.0" \
    -module-cache-path "$FILETREE_TEST_WORK/module-cache" \
    "$FILETREE_TEST_WORK/Check.swift" -o "$FILETREE_TEST_WORK/check"
"$FILETREE_TEST_WORK/check" "$@"
