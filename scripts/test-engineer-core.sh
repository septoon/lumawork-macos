#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec swift test --package-path "$project_root/Packages/EngineerCore" "$@"
