#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p .codex-tmp
build_log="$project_root/.codex-tmp/macos-build.log"
if ! xcodebuild -project EngineerMac.xcodeproj -scheme EngineerMac \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath .codex-tmp/macos-derived-data \
    CODE_SIGNING_ALLOWED=NO build > "$build_log" 2>&1; then
    tail -80 "$build_log" >&2
    exit 1
fi
tail -3 "$build_log"
