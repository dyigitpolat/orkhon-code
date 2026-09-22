#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/work/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/work/module-cache"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    print -u2 "Orkhon Code currently builds on Apple silicon Macs."
    exit 2
fi
xcrun --find swiftc >/dev/null
command -v python3 >/dev/null || { print -u2 "Install Python 3 before building."; exit 2; }
mkdir -p work outputs
python3 scripts/verify_preview_assets.py
python3 scripts/build_native.py
python3 scripts/generate_languages.py
python3 scripts/generate_style_names.py
swift build -c release --disable-sandbox --cache-path work/swift-cache --config-path work/swift-config --security-path work/swift-security
swiftc -O scripts/make_icon.swift -o work/make_icon
work/make_icon work/AppIcon.iconset
iconutil -c icns work/AppIcon.iconset -o work/AppIcon.icns
swiftc -O scripts/make_document_icon.swift -o work/make_document_icon
work/make_document_icon work/DocumentIcon.iconset work/AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns work/DocumentIcon.iconset -o work/DocumentIcon.icns
python3 scripts/package.py

python3 scripts/build_installer.py
