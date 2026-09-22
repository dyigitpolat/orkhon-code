#!/bin/bash
# Build and run the native editor bridge regression harness on macOS.
# Prerequisite: python3 scripts/build_native.py
# AppKit runtime checks require a logged-in macOS GUI session.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

for archive in work/build/native/libscintilla.a work/build/native/liblexilla.a; do
    if [[ ! -f "$archive" ]]; then
        printf 'Missing %s. Run python3 scripts/build_native.py first.\n' "$archive" >&2
        exit 1
    fi
done

mkdir -p work/build/tests

test_executable="$(mktemp -u "$PWD/work/build/tests/editor-XXXXXX")"
trap 'rm -f "$test_executable"' EXIT
clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror \
    -mmacosx-version-min=13.0 \
    -ISources/EditorBridge/include \
    -IVendor/scintilla/include \
    -IVendor/scintilla/cocoa \
    -IVendor/lexilla/include \
    Sources/EditorBridge/EditorBridge.mm \
    scripts/test_editor.mm \
    work/build/native/libscintilla.a \
    work/build/native/liblexilla.a \
    -framework Cocoa -framework QuartzCore -framework CoreText \
    -o "$test_executable"

"$test_executable"
