#!/bin/bash
# Script Filter for the `sum` keyword. Prints the two rows, "Active window"
# then "Clipboard", narrowed by the typed query.
#
#   rows.sh [query]
#
# Each subtitle previews what Enter would send. Building the rows reads the
# clipboard and asks lsappinfo for the frontmost app, nothing slower: no
# AppleScript, no network, no backend. Whatever fails, the output is one
# valid {"items":[...]} object and the exit code is 0, because Alfred shows
# nothing at all for broken Script Filter output.
set -uo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Characters of clipboard text shown in the Clipboard row's subtitle.
PREVIEW_CHARS=60

window_subtitle() {
  if [ -z "$APP_ID" ]; then
    echo "No active window"
    return
  fi
  case "$(app_kind "$APP_ID")" in
    safari | chromium) echo "$APP_NAME: selection or page text" ;;
    mail) echo "$APP_NAME: selected message" ;;
    *) echo "$APP_NAME: not supported" ;;
  esac
}

clipboard_subtitle() {
  local text host
  text=$(tool_run SUM_PBPASTE pbpaste 5 2>/dev/null | text_pl trim)
  if [ -z "$text" ]; then
    echo "empty"
  elif host=$(text_pl url-host "$text"); then
    echo "$host"
  else
    printf '%s' "$text" | text_pl preview "$PREVIEW_CHARS"
  fi
}

main() {
  local query="${1:-}" json
  setup_env
  front_app
  if ! json=$(text_pl items "$query" "$(window_subtitle)" "$(clipboard_subtitle)" "$APP_ID" "$APP_NAME"); then
    json='{"items":[]}'
  fi
  printf '%s\n' "$json"
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
