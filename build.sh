#!/bin/bash
# Package the workflow into dist/Summarize.alfredworkflow, a plain zip of
# info.plist, prompt.md, scripts/ and an optional icon that Alfred imports.
set -euo pipefail
cd "$(dirname "$0")"

OUT="dist/Summarize.alfredworkflow"

command -v zip >/dev/null 2>&1 || { echo "ERROR: zip not found on PATH" >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "ERROR: unzip not found on PATH" >&2; exit 1; }

# Alfred runs the Text View's script file directly, so it needs its execute
# bit inside the archive. nullglob so an empty match doesn't hand chmod the
# literal pattern and abort the build under `set -e`.
shopt -s nullglob
scripts=(scripts/*.sh scripts/*.pl)
shopt -u nullglob
if [[ ${#scripts[@]} -gt 0 ]]; then
  chmod +x "${scripts[@]}"
fi

mkdir -p dist
rm -f "$OUT"

FILES=(info.plist prompt.md scripts)
[[ -f icon.png ]] && FILES+=(icon.png)

zip -r "$OUT" "${FILES[@]}" -x '*.DS_Store' >/dev/null

echo "Built $OUT"
unzip -l "$OUT"
