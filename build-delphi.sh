#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBS_PLUGIN_ROOT="${OBS_PLUGIN_ROOT:-$ROOT/../OBSPlugin}"

if [[ ! -f "$OBS_PLUGIN_ROOT/Source/XENOME.OBS.Compatibility.pas" ]]; then
  printf 'DelphiOBS v0.2.0 bindings not found. Clone nalilord/DelphiOBS to ../OBSPlugin or set OBS_PLUGIN_ROOT.\n' >&2
  exit 1
fi

SOURCE_PATHS="Source;$OBS_PLUGIN_ROOT/Source" \
  "$ROOT/build-wsl-generic.sh" OBSAPNGPlugin.dpr Win64

printf 'Plugin is ready in %s\n' "$ROOT/Bin/Win64"
