#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWERSHELL="${POWERSHELL:-/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}"
args=(-NoProfile -File "$(wslpath -w "$ROOT/build.ps1")")
if [[ -n "${OBS_PLUGIN_ROOT:-}" ]]; then
  args+=(-OBSPluginRoot "$(wslpath -w "$OBS_PLUGIN_ROOT")")
fi
"$POWERSHELL" "${args[@]}" "$@"
