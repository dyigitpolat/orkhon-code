#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/work/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/work/module-cache"
swift -module-cache-path "$PWD/work/module-cache" scripts/test_storage.swift
scripts/test_editor.sh
scripts/test_filetree.sh
scripts/test_terminal.sh
python3 scripts/generate_languages.py --check
python3 scripts/test_workspace_watch.py
swiftc Sources/Lumen/AssociationPolicy.swift scripts/test_associations.swift -o work/test-associations
work/test-associations
swiftc Sources/Lumen/WorkspacePaths.swift scripts/test_workspace.swift -o work/test-workspace
work/test-workspace
swiftc -O Sources/LumenCore/ExternalMerge.swift scripts/test_external_merge.swift -o work/test-merge
work/test-merge
swiftc -O Sources/Lumen/RemoteWorkspace.swift scripts/test_remote.swift -o work/test-remote
work/test-remote
app_path=$(cat work/staged-app-path.txt)
python3 scripts/test_integration.py "$app_path"
python3 scripts/test_startup.py "$app_path"
codesign --verify --deep --strict "$app_path"
