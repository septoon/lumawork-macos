#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mode="${1:-run}"
case "$mode" in run|--debug|--logs|--telemetry|--verify) ;; *) echo "usage: $0 [--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;; esac
app_bundle="$project_root/.codex-tmp/macos-derived-data/Build/Products/Debug/EngineerMac.app"
app_binary="$app_bundle/Contents/MacOS/EngineerMac"
# Only this project's running binary is stopped; never another EngineerMac build.
while read -r app_pid; do
    [[ -n "$app_pid" ]] && kill "$app_pid" 2>/dev/null || true
done < <(pgrep -f "^$app_binary($| )" || true)
./scripts/build-macos.sh
case "$mode" in
    --debug) exec lldb -- "$app_binary" ;;
    --logs) /usr/bin/open -n "$app_bundle"; exec /usr/bin/log stream --info --style compact --predicate 'process == "EngineerMac"' ;;
    --telemetry) /usr/bin/open -n "$app_bundle"; exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "septon.LumaWork.mac"' ;;
    --verify) /usr/bin/open -n "$app_bundle"; sleep 1; pgrep -f "^$app_binary($| )" ;;
    run) /usr/bin/open -n "$app_bundle" ;;
esac
