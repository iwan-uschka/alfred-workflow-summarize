#!/bin/bash
# shellcheck disable=SC2016 # single quotes hold Perl expressions for json_get
# Tests for scripts/rows.sh, the Script Filter. pbpaste and lsappinfo are
# stubs (see test/stubs.sh), so the rows reflect whatever each case sets.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/rows.sh"
# shellcheck source=test/helpers.sh
source "$ROOT/test/helpers.sh"
# shellcheck source=test/stubs.sh
source "$ROOT/test/stubs.sh"

# rows [query]: runs the Script Filter; sets out, code, calls.
rows() {
  : >"$STUB_LOG"
  out=$(bash "$SCRIPT" "$@" 2>/dev/null)
  code=$?
  calls=$(cat "$STUB_LOG")
}

titles() { printf '%s' "$out" | json_get 'join "|", map { $_->{title} } @{$d->{items}}'; }
subtitle() { printf '%s' "$out" | json_get "join '', map { \$_->{subtitle} } grep { \$_->{title} eq '$1' } @{\$d->{items}}"; }

# --- two rows, fixed order, no uid, args and the app passed on ---
reset_stubs
front com.apple.Safari Safari
clip "Some clipboard text"
rows
assert_eq "exit code" "0" "$code"
assert_eq "both rows in fixed order" "Active window|Clipboard" "$(titles)"
assert_eq "args" "window|clipboard" "$(printf '%s' "$out" | json_get 'join "|", map { $_->{arg} } @{$d->{items}}')"
# breaks-if: someone adds a uid, and Alfred starts reordering the rows by use
assert_eq "no uid on any row" "0" "$(printf '%s' "$out" | json_get 'scalar grep { exists $_->{uid} } @{$d->{items}}')"
assert_eq "front app id passed on" "com.apple.Safari" "$(printf '%s' "$out" | json_get '$d->{items}[0]{variables}{sum_app_id}')"
assert_eq "front app name passed on" "Safari" "$(printf '%s' "$out" | json_get '$d->{items}[1]{variables}{sum_app_name}')"
assert_eq "Safari subtitle" "Safari: selection or page text" "$(subtitle 'Active window')"
assert_eq "clipboard text preview" "Some clipboard text" "$(subtitle Clipboard)"
# breaks-if: rows.sh starts asking an app through AppleScript, which is slow and can prompt
refute_contains "building rows never runs osascript" "$calls" "osascript"

# --- the Active window subtitle per app ---
for pair in "com.google.Chrome|Google Chrome|Google Chrome: selection or page text" \
    "com.brave.Browser|Brave Browser|Brave Browser: selection or page text" \
    "com.apple.mail|Mail|Mail: selected message" \
    "org.mozilla.firefox|Firefox|Firefox: not supported" \
    "com.apple.Notes|Notes|Notes: not supported"; do
  IFS='|' read -r id name want <<<"$pair"
  front "$id" "$name"
  rows
  assert_eq "subtitle for $id" "$want" "$(subtitle 'Active window')"
done
front "" ""
rows
assert_eq "no front app" "No active window" "$(subtitle 'Active window')"

# --- the Clipboard subtitle ---
front com.apple.Safari Safari
clip "https://www.example.com/some/article?id=1"
rows
assert_eq "URL shows its host" "www.example.com" "$(subtitle Clipboard)"
clip $'  \n https://example.org/x \n'
rows
assert_eq "URL with surrounding whitespace shows its host" "example.org" "$(subtitle Clipboard)"
clip $'https://example.org/x\nsecond line'
rows
assert_eq "multi-line text starting with a URL is text" "https://example.org/x second line" "$(subtitle Clipboard)"
clip "example.com/page"
rows
assert_eq "bare domain is text" "example.com/page" "$(subtitle Clipboard)"
clip "http://"
rows
assert_eq "lone http:// is text" "http://" "$(subtitle Clipboard)"
clip ""
rows
assert_eq "empty clipboard" "empty" "$(subtitle Clipboard)"
clip $' \n\t '
rows
assert_eq "whitespace-only clipboard is empty" "empty" "$(subtitle Clipboard)"
s60=$(printf 'x%.0s' $(seq 1 60))
clip "${s60}"
rows
assert_eq "60 characters shown whole" "$s60" "$(subtitle Clipboard)"
clip "${s60}yz"
rows
# breaks-if: the preview length changes from 60 characters
assert_eq "longer text cut to 60 characters" "${s60}…" "$(subtitle Clipboard)"

# --- filtering by the typed query ---
clip "text"
rows "cl"
assert_eq "prefix narrows to Clipboard" "Clipboard" "$(titles)"
rows "WIN"
assert_eq "substring in any case narrows to Active window" "Active window" "$(titles)"
rows "board"
assert_eq "substring narrows to Clipboard" "Clipboard" "$(titles)"
rows "  clip "
assert_eq "surrounding spaces ignored" "Clipboard" "$(titles)"
rows "i"
assert_eq "a letter both titles hold keeps both, in order" "Active window|Clipboard" "$(titles)"
rows ""
assert_eq "empty query keeps both" "Active window|Clipboard" "$(titles)"
# breaks-if: a query that matches neither row falls back to showing both
rows "zzz"
assert_eq "no match exit code" "0" "$code"
assert_eq "no match is valid JSON with no items" "0" "$(printf '%s' "$out" | json_get 'scalar @{$d->{items}}')"

# --- tool failures still give valid JSON and exit 0 ---
# breaks-if: a failing pbpaste aborts the Script Filter
export STUB_PBPASTE_FAIL=1
rows
assert_eq "pbpaste failing exit code" "0" "$code"
assert_eq "pbpaste failing still shows both rows" "Active window|Clipboard" "$(titles)"
assert_eq "pbpaste failing shows empty" "empty" "$(subtitle Clipboard)"
unset STUB_PBPASTE_FAIL
# breaks-if: a failing lsappinfo aborts the Script Filter
export STUB_LSAPPINFO_FAIL=1
rows
assert_eq "lsappinfo failing exit code" "0" "$code"
assert_eq "lsappinfo failing shows no window" "No active window" "$(subtitle 'Active window')"
export STUB_PBPASTE_FAIL=1
rows
assert_eq "both failing exit code" "0" "$code"
assert_eq "both failing still valid JSON" "Active window|Clipboard" "$(titles)"
unset STUB_PBPASTE_FAIL STUB_LSAPPINFO_FAIL

# A broken text.pl: rows.sh falls back to an empty, still valid, item list.
BROKEN=$(mktemp -d)
cp -R "$ROOT/scripts" "$BROKEN/scripts"
printf 'exit 2;\n' >"$BROKEN/scripts/text.pl"
out=$(bash "$BROKEN/scripts/rows.sh" "" 2>/dev/null)
code=$?
rm -rf "$BROKEN"
# breaks-if: the fallback JSON in rows.sh main is removed
assert_eq "broken helper exit code" "0" "$code"
assert_eq "broken helper output" '{"items":[]}' "$out"

# --- the Script Filter as info.plist wires it ---
keyword=$(plutil -extract objects.0.config.keyword raw -o - "$ROOT/info.plist")
assert_eq "keyword comes from the SUM_KEYWORD variable" "{var:SUM_KEYWORD}" "$keyword"
assert_eq "keyword variable defaults to sum" "sum" \
  "$(plutil -extract userconfigurationconfig.0.config.default raw -o - "$ROOT/info.plist")"
assert_eq "keyword variable name" "SUM_KEYWORD" \
  "$(plutil -extract userconfigurationconfig.0.variable raw -o - "$ROOT/info.plist")"
assert_eq "Alfred does not filter or reorder" "false" \
  "$(plutil -extract objects.0.config.alfredfiltersresults raw -o - "$ROOT/info.plist")"
script_line=$(plutil -extract objects.0.config.script raw -o - "$ROOT/info.plist")
front com.apple.Safari Safari
clip "hello"
out=$(cd "$ROOT" && bash -c "$script_line" sum "clip" 2>/dev/null)
assert_eq "plist command line runs the filter" "Clipboard" "$(titles)"

finish_tests
