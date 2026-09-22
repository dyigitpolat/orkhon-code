#!/bin/bash
# Build the actual TerminalPanel and pinned SwiftTerm, then exercise real zsh PTYs.
# Requires macOS, Swift 6.0 or later, and a logged-in macOS GUI session for AppKit.
# No network, full Xcode installation, or editor/native-library build is required.
# Outputs and the shareable report stay in work/build/terminal-tests/.
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'HELP'
Usage: scripts/test_terminal.sh

Build and run Orkhon Code's native terminal integration checks.
Requires macOS, Command Line Tools with Swift 6.0+, a logged-in GUI session,
and the existing Vendor/SwiftTerm v1.10.1 sources. Downloads nothing.

Checks compile compatibility in Swift 5 and Swift 6 language modes; runtime
checks use Swift 6 and real zsh PTYs. Each run isolates shell startup/history
in a temporary directory and cleans up its sessions on success or failure.

Report: work/build/terminal-tests/report.txt
Exit status: 0 on success; nonzero on a build error or failed runtime check.
HELP
    exit 0
fi
if [[ $# -ne 0 ]]; then
    printf 'Unexpected argument. Use --help for usage.\n' >&2
    exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'The native terminal tests require macOS.\n' >&2
    exit 2
fi

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
root="$PWD"
build_dir="$root/work/build/terminal-tests"
vendor_dir="$root/Vendor/SwiftTerm"
mkdir -p "$build_dir/module-cache" "$build_dir/runtime"

run_suite() {
    printf 'Orkhon Code — native terminal validation\n'
    date -u '+Run started: %Y-%m-%d %H:%M:%S UTC'
    printf 'Report: %s/report.txt\n' "$build_dir"
    xcrun swiftc --version
    if [[ ! -f "$vendor_dir/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift" ]]; then
        printf 'Missing Vendor/SwiftTerm v1.10.1 sources.\n' >&2
        return 2
    fi
    if [[ -d "$vendor_dir/.git" || -f "$vendor_dir/.git" ]]; then
        local revision
        revision="$(git -C "$vendor_dir" rev-parse HEAD)"
        printf 'SwiftTerm revision: %s\n' "$revision"
        if [[ "$revision" != "5c83a9d214e7354697624c11deb4e488bdcfabad" ]]; then
            printf 'Expected the pinned SwiftTerm v1.10.1 revision.\n' >&2
            return 2
        fi
    else
        printf 'SwiftTerm: vendored export (expected v1.10.1; no git metadata)\n'
    fi

    local sources=()
    local source
    while IFS= read -r -d '' source; do
        sources+=("$source")
    done < <(find "$vendor_dir/Sources/SwiftTerm" -type f -name '*.swift' -print0)
    if [[ ${#sources[@]} -eq 0 ]]; then
        printf 'No SwiftTerm sources found.\n' >&2
        return 2
    fi

    printf '\nBuilding the vendored SwiftTerm library…\n'
    xcrun swiftc -swift-version 5 -whole-module-optimization \
        -emit-library -emit-module -module-name SwiftTerm \
        -module-cache-path "$build_dir/module-cache" \
        -emit-module-path "$build_dir/SwiftTerm.swiftmodule" \
        -Xlinker -install_name -Xlinker '@rpath/libSwiftTerm.dylib' \
        "${sources[@]}" -o "$build_dir/libSwiftTerm.dylib"

    printf '\nCompiling TerminalPanel in Swift 5 mode…\n'
    xcrun swiftc -swift-version 5 -parse-as-library -typecheck \
        -I "$build_dir" -module-cache-path "$build_dir/module-cache" \
        "$root/Sources/Lumen/RemoteWorkspace.swift" "$root/Sources/Lumen/TabScrollView.swift" "$root/Sources/Lumen/TerminalPanel.swift"
    printf 'PASS: Swift 5 language-mode compilation\n'

    printf '\nBuilding the Swift 6 runtime harness…\n'
    xcrun swiftc -swift-version 6 -parse-as-library \
        -I "$build_dir" -L "$build_dir" -lSwiftTerm \
        -Xlinker -rpath -Xlinker "$build_dir" \
        -module-cache-path "$build_dir/module-cache" \
        "$root/Sources/Lumen/RemoteWorkspace.swift" "$root/Sources/Lumen/TabScrollView.swift" "$root/Sources/Lumen/TerminalPanel.swift" "$root/scripts/test_terminal.swift" \
        -o "$build_dir/test_terminal"
    printf 'PASS: Swift 6 language-mode compilation\n\n'
    "$build_dir/test_terminal" "$build_dir/runtime"
}

# pipefail preserves compiler/test failures while keeping a release report.
run_suite 2>&1 | tee "$build_dir/report.txt"
