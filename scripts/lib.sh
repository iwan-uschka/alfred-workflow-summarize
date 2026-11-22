#!/bin/bash
# Shared setup for rows.sh and summarize.sh. Source it; it runs nothing on
# its own.
#
# Must stay compatible with /bin/bash 3.2 (what Alfred runs): no mapfile, no
# associative arrays, and an empty array can't be expanded under `set -u`.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # used by summarize.sh
WORKFLOW_DIR="$(cd "$LIB_DIR/.." && pwd)"

# The system Perl, not whatever Homebrew put first on PATH: the helpers rely
# on its core modules only, and its path is the same on every Mac.
PERL=/usr/bin/perl

# The command the "Active window" and "Clipboard" rows feed by default. Kept
# in sync with the default in info.plist; test/summarize.test.sh checks that.
# shellcheck disable=SC2016,SC2034 # expanded later by zsh, not here
DEFAULT_COMMAND='claude -p --model "$SUM_MODEL" --tools "" --strict-mcp-config --no-session-persistence --system-prompt "$SUM_PROMPT"'

text_pl() { "$PERL" "$LIB_DIR/text.pl" "$@"; }

# tool_run VAR DEFAULT SECONDS [ARGS...]: runs the external tool DEFAULT, or
# the command line in the variable named VAR when that is not blank, killed after
# SECONDS. The command line is split on spaces. Tests use VAR to swap
# pbpaste, lsappinfo, osascript, curl and textutil for stubs, for example
# SUM_CURL="/bin/bash /tmp/stubs/curl".
tool_run() {
  local spec="${!1:-$2}" tool="$2" secs="$3" words
  shift 3
  read -r -a words <<<"$spec"
  # A blank VAR splits into no words, which `set -u` can't expand, so it
  # falls back to DEFAULT like an empty one.
  [ "${#words[@]}" -gt 0 ] || words=("$tool")
  "$PERL" "$LIB_DIR/timeout.pl" "$secs" "${words[@]}" "$@"
}

setup_env() {
  # Alfred runs scripts with PATH=/usr/bin:/bin:/usr/sbin:/sbin, where a
  # `claude` installed by Homebrew, the native installer or npm is missing.
  # Prepend, so the backend found here is the one a terminal would find.
  local dir add=""
  for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.claude/local" \
      "$HOME/.npm-global/bin" "$HOME/.volta/bin" ${NPM_CONFIG_PREFIX:+"$NPM_CONFIG_PREFIX/bin"}; do
    [ -d "$dir" ] && add="$add$dir:"
  done
  PATH="$add$PATH"
  export PATH
  # pbpaste and textutil decode and encode text by the locale, and Alfred's
  # environment has none. Without it, every non-ASCII character is mangled.
  export LANG=en_US.UTF-8
}

# Sets APP_ID (bundle id) and APP_NAME for the frontmost app, both empty if
# there is none. lsappinfo needs no Automation permission. While Alfred's
# window is open, it still reports the app the user was working in.
front_app() {
  local asn info
  APP_ID=""
  APP_NAME=""
  asn=$(tool_run SUM_LSAPPINFO lsappinfo 5 front 2>/dev/null) || return 0
  [ -n "$asn" ] || return 0
  info=$(tool_run SUM_LSAPPINFO lsappinfo 5 info -only bundleid -only name "$asn" 2>/dev/null) || return 0
  APP_ID=$(printf '%s\n' "$info" | sed -n 's/.*"CFBundleIdentifier"="\(.*\)".*/\1/p' | head -n 1)
  APP_NAME=$(printf '%s\n' "$info" | sed -n 's/.*"LSDisplayName"="\(.*\)".*/\1/p' | head -n 1)
  [ -n "$APP_NAME" ] || APP_NAME="$APP_ID"
}

# The strict allowlist. Prints safari, chromium or mail for a supported
# bundle id, nothing for anything else. Not configurable on purpose; see
# AGENTS.md.
app_kind() {
  case "$1" in
    com.apple.Safari) echo safari ;;
    com.google.Chrome | com.brave.Browser) echo chromium ;;
    com.apple.mail) echo mail ;;
  esac
}
