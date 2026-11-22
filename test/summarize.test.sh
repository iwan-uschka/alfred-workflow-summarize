#!/bin/bash
# shellcheck disable=SC2016,SC2031 # single quotes hold Perl and zsh code; the subshell only reads
# Flow tests for scripts/summarize.sh, the Text View script. Each case runs
# the script the way Alfred does: once with the row's argument, then again
# with the `sum_job` variable from the previous output for as long as that
# output asks for a rerun. The backend, pbpaste, lsappinfo, osascript and
# curl are stubs (see test/stubs.sh); textutil and perl are the real ones,
# except in the two conversion-failure cases, which stub textutil through
# SUM_TEXTUTIL.
#
# No case can reach the real `claude`. SUM_COMMAND always names the stub,
# and the cases that need a command whose first word is `claude` point
# ZDOTDIR at a .zshenv that defines `claude` as a shell function calling the
# stub. zsh runs a function before it looks at PATH. Those cases also point
# HOME at an empty directory, so setup_env adds no ~/.local/bin or other
# directory under HOME to PATH, and test/stubs.sh clears NPM_CONFIG_PREFIX.
# /opt/homebrew/bin and /usr/local/bin still come first on PATH, so the
# function is what keeps a `claude` installed there from running.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/summarize.sh"
FIXTURES="$ROOT/test/fixtures"
# shellcheck source=test/helpers.sh
source "$ROOT/test/helpers.sh"
# shellcheck source=test/stubs.sh
source "$ROOT/test/stubs.sh"

export alfred_workflow_cache="$STUBS/cache"
JOBS="$alfred_workflow_cache/jobs"

# render_fields: reads one Text View JSON object and prints "rerun|sum_job"
# on the first line and the response after it. rerun is "-" when absent.
render_fields() {
  json_get 'my $r = exists $d->{rerun} ? $d->{rerun} : "-";
    "$r|" . ($d->{variables}{sum_job} // "UNSET") . "\n" . ($d->{response} // "")'
}

# summarize SOURCE: runs the full rerun loop. Sets first (first JSON), out
# (final response), final_job (final sum_job), renders (how many runs),
# running (every response shown while the job ran), calls (stub log).
summarize() {
  local json fields head job i
  : >"$STUB_LOG"
  json=$(sum_job="" bash "$SCRIPT" "$1" 2>/dev/null)
  first="$json"
  renders=1
  running=""
  for ((i = 0; i < 400; i++)); do
    fields=$(printf '%s' "$json" | render_fields)
    head=${fields%%$'\n'*}
    [ "${head%%|*}" = "-" ] && break
    running="$running${fields#*$'\n'}"$'\n---\n'
    job=${head#*|}
    sleep 0.05
    json=$(sum_job="$job" bash "$SCRIPT" "$1" 2>/dev/null)
    renders=$((renders + 1))
  done
  [ "$i" -lt 400 ] || not_ok "summarize $1: still asking for a rerun after 400 renders"
  out=${fields#*$'\n'}
  final_job=${head#*|}
  calls=$(cat "$STUB_LOG")
}

# window_app ID NAME: the app the Script Filter would have passed on.
window_app() { export sum_app_id="$1" sum_app_name="$2"; }

osa_out() { printf '%s' "$1" >"$STUB_OSA_OUT_FILE"; }

cmd_ran() { grep -qx cmd <<<"$calls" && echo yes || echo no; }

jobs_left() { find "$JOBS" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }

HINT='Open the page in your browser and use the "Active window" row.'

# ===================================================== clipboard: text

reset_stubs
clip $'  Plain clipboard text.\nSecond line.  \n'
summarize clipboard
assert_eq "text: backend got the trimmed clipboard" $'Plain clipboard text.\nSecond line.' "$(cat "$STUBS/cmd.stdin")"
assert_contains "text: summary shown" "$out" "TL;DR: stub summary."
assert_contains "text: first render asks for a rerun" "$first" '"rerun":0.3'
assert_contains "text: first render carries the job" "$first" "\"sum_job\":\"$JOBS/job."
# breaks-if: the final render keeps rerun, and Alfred polls forever
assert_eq "text: final render clears the job" "" "$final_job"
assert_eq "text: no job directory left" "0" "$(jobs_left)"
refute_contains "text: no fetch for plain text" "$calls" "curl"

# ===================================================== clipboard: URLs

reset_stubs
cp "$FIXTURES/article.html" "$STUB_PAGE"
clip "https://example.com/tide-pools"
summarize clipboard
assert_contains "url: curl called with the URL" "$calls" "https://example.com/tide-pools"
assert_contains "url: curl follows redirects" "$calls" " -L "
assert_contains "url: curl gets the fetch timeout" "$calls" "--max-time 15 "
assert_contains "url: curl sends a browser User-Agent" "$calls" "-A Mozilla/5.0"
# breaks-if: the download size cap is removed and a huge page is read into memory
assert_contains "url: curl caps the download size" "$calls" "--max-filesize 20000000 "
# breaks-if: -q moves off the first position, where curl needs it to skip ~/.curlrc
assert_eq "url: curl ignores ~/.curlrc" "curl -q " "$(grep '^curl ' <<<"$calls" | cut -c 1-8)"
# breaks-if: --proto or --proto-redir is dropped and a redirect to ftp or file is followed
assert_contains "url: curl fetches only http and https" "$calls" " --proto =http,https --proto-redir =http,https "
# breaks-if: the redirect limit is dropped and curl follows up to 50 redirects
assert_contains "url: curl follows at most 5 redirects" "$calls" " --max-redirs 5 "
stdin=$(cat "$STUBS/cmd.stdin")
assert_contains "url: backend gets the URL line" "$stdin" "URL: https://example.com/tide-pools"
assert_contains "url: backend gets the page text" "$stdin" "Volunteers counted 412 sea stars"
refute_contains "url: backend gets no script text" "$stdin" "TRACKER_SCRIPT_TEXT"
assert_contains "url: summary shown" "$out" "TL;DR: stub summary."

reset_stubs
cp "$FIXTURES/article.html" "$STUB_PAGE"
clip $'\n   https://example.com/x   \n'
summarize clipboard
assert_contains "url with surrounding whitespace is fetched" "$calls" "curl"

reset_stubs
cp "$FIXTURES/article.html" "$STUB_PAGE"
clip "https://example.com/page[1-99999999]{a,b}"
summarize clipboard
# breaks-if: --globoff is dropped and curl expands the brackets into one request per number
assert_contains "url: curl turns off URL globbing" "$calls" " --globoff "
assert_eq "url: a URL with brackets reaches curl unexpanded, as the last argument" \
  " https://example.com/page[1-99999999]{a,b}" "$(grep '^curl ' <<<"$calls" | grep -o ' [^ ]*$')"

reset_stubs
clip $'https://example.com/x\nNotes about the page.'
summarize clipboard
# breaks-if: the URL check looks only at the first line
refute_contains "multi-line text starting with a URL is not fetched" "$calls" "curl"
assert_eq "multi-line text is sent as is" $'https://example.com/x\nNotes about the page.' "$(cat "$STUBS/cmd.stdin")"

reset_stubs
clip "example.com/page"
summarize clipboard
# breaks-if: the URL check stops requiring an http or https scheme
refute_contains "bare domain is not fetched" "$calls" "curl"
assert_eq "bare domain is sent as text" "example.com/page" "$(cat "$STUBS/cmd.stdin")"

reset_stubs
clip "http://"
summarize clipboard
# breaks-if: a lone scheme is treated as a URL and fetched
refute_contains "lone http:// is not fetched" "$calls" "curl"
assert_eq "lone http:// is sent as text" "http://" "$(cat "$STUBS/cmd.stdin")"

pad=$(printf 'a%.0s' $(seq 1 2028))
reset_stubs
cp "$FIXTURES/article.html" "$STUB_PAGE"
clip "https://example.com/$pad"
summarize clipboard
assert_contains "a 2048-character URL is fetched" "$calls" "https://example.com/$pad"
reset_stubs
clip "https://example.com/${pad}a"
summarize clipboard
# breaks-if: read_clipboard calls a URL check other than url-host, with its own or no length limit
refute_contains "a 2049-character URL is not fetched" "$calls" "curl"
assert_eq "a 2049-character URL is sent as text" "https://example.com/${pad}a" "$(cat "$STUBS/cmd.stdin")"
reset_stubs
long="https://example.com/$(/usr/bin/perl -e 'print "a" x 300000')"
clip "$long"
summarize clipboard
# breaks-if: url_host loses its length limit and the job fetches a 300 KB link
refute_contains "a 300 KB URL is not fetched" "$calls" "curl"
assert_eq "a 300 KB URL reaches the command as text" "${long:0:200000}" "$(cat "$STUBS/cmd.stdin")"
assert_contains "a 300 KB URL is summarized" "$out" "TL;DR: stub summary."

reset_stubs
printf 'Caf\xe9 cr\xe8me. %s\n' "$(printf 'Latin-1 page text. %.0s' $(seq 1 15))" >"$STUB_PAGE"
export STUB_CTYPE="text/html; charset=ISO-8859-1"
clip "https://example.com/latin1"
summarize clipboard
assert_contains "charset from Content-Type decodes the page" "$(cat "$STUBS/cmd.stdin")" "Café crème."

reset_stubs
printf 'Caf\xe9 cr\xe8me. %s\n' "$(printf 'Latin-1 page text. %.0s' $(seq 1 15))" >"$STUB_PAGE"
export STUB_CTYPE='text/html; charset="ISO-8859-1"'
clip "https://example.com/latin1-quoted"
summarize clipboard
# breaks-if: the Content-Type parser stops accepting a quoted charset value
assert_contains "quoted charset from Content-Type decodes the page" "$(cat "$STUBS/cmd.stdin")" "Café crème."

reset_stubs
printf 'Caf\xe9 cr\xe8me. %s\n' "$(printf 'Latin-1 page text. %.0s' $(seq 1 15))" >"$STUB_PAGE"
export STUB_CTYPE='Text/HTML; Charset=ISO-8859-1'
clip "https://example.com/upper-case-type"
summarize clipboard
# breaks-if: fetch_page stops lower-casing the Content-Type before matching it
assert_contains "mixed-case Content-Type is read as HTML with its charset" "$(cat "$STUBS/cmd.stdin")" "Café crème."

reset_stubs
# The fixture's text must stay above MIN_PAGE_CHARS (200), or this case fails
# with "too little text" instead of a charset assertion.
cp "$FIXTURES/meta-latin1.html" "$STUB_PAGE"
export STUB_CTYPE="text/html"
clip "https://example.com/meta-only"
summarize clipboard
# breaks-if: strip-html removes <meta> before the page's own charset is read
assert_contains "charset from <meta> alone decodes the page" "$(cat "$STUBS/cmd.stdin")" "Café crème in Latin-1."

reset_stubs
cp "$FIXTURES/article.html" "$STUB_PAGE"
export STUB_CTYPE="application/xhtml+xml; charset=utf-8"
clip "https://example.com/xhtml"
summarize clipboard
# breaks-if: application/xhtml+xml is no longer treated as HTML
assert_contains "XHTML page is converted" "$(cat "$STUBS/cmd.stdin")" "Volunteers counted"
refute_contains "XHTML page drops its scripts" "$(cat "$STUBS/cmd.stdin")" "TRACKER_SCRIPT_TEXT"

reset_stubs
printf 'Caf\xe9 cr\xe8me. %s\n' "$(printf 'Latin-1 plain text. %.0s' $(seq 1 15))" >"$STUB_PAGE"
export STUB_CTYPE="text/plain; charset=iso-8859-1"
clip "https://example.com/latin1.txt"
summarize clipboard
# breaks-if: plain text ignores the Content-Type charset and is read as UTF-8
assert_contains "charset from Content-Type decodes plain text" "$(cat "$STUBS/cmd.stdin")" "Café crème."

reset_stubs
printf '# Notes\n\nGrüße. %s\n' "$(printf 'Markdown text. %.0s' $(seq 1 15))" >"$STUB_PAGE"
export STUB_CTYPE="text/markdown"
clip "https://example.com/notes.md"
summarize clipboard
assert_contains "Markdown without a charset is read as UTF-8" "$(cat "$STUBS/cmd.stdin")" "# Notes"$'\n\n'"Grüße."

reset_stubs
printf '# Notes\n\nCaf\xe9. %s\n' "$(printf 'Markdown text. %.0s' $(seq 1 15))" >"$STUB_PAGE"
export STUB_CTYPE="text/markdown; charset=iso-8859-1"
clip "https://example.com/notes-latin1.md"
summarize clipboard
# breaks-if: the text/markdown; <params> alternative is removed from the plain-text case
assert_contains "Markdown with a charset is decoded with it" "$(cat "$STUBS/cmd.stdin")" "Café."

reset_stubs
printf 'Gr\xc3\xbc\xc3\x9fe. %s\n' "$(printf 'Dotted charset text. %.0s' $(seq 1 15))" >"$STUB_PAGE"
export STUB_CTYPE="text/plain; charset=ansi_x3.4-1968"
clip "https://example.com/dotted.txt"
summarize clipboard
# breaks-if: the charset parser stops at a dot and reads this page as UTF-8 instead of ASCII
refute_contains "charset name with a dot is read whole" "$(cat "$STUBS/cmd.stdin")" "Grüße."

reset_stubs
cp "$FIXTURES/article.html" "$STUB_PAGE"
export STUB_CTYPE=""
clip "https://example.com/no-type"
summarize clipboard
assert_contains "missing Content-Type is treated as HTML" "$(cat "$STUBS/cmd.stdin")" "Volunteers counted"

# ===================================================== clipboard: failures

reset_stubs
clip ""
summarize clipboard
# breaks-if: the empty-clipboard check in read_clipboard is removed
assert_eq "empty clipboard message" "Nothing to summarize." "$out"
assert_eq "empty clipboard sends nothing" "no" "$(cmd_ran)"

reset_stubs
clip $' \n\t '
summarize clipboard
# breaks-if: read_clipboard stops trimming before its empty check
assert_eq "whitespace-only clipboard message" "Nothing to summarize." "$out"

reset_stubs
export STUB_PBPASTE_FAIL=1
summarize clipboard
# breaks-if: a failing pbpaste is read as an empty or valid clipboard
assert_contains "pbpaste failure message" "$out" "Could not read the clipboard: pbpaste: no pasteboard"
assert_eq "pbpaste failure sends nothing" "no" "$(cmd_ran)"

reset_stubs
clip "Text"
export STUB_PBPASTE_HANG=1 SUM_APP_TIMEOUT=1
start=$SECONDS
summarize clipboard
unset SUM_APP_TIMEOUT
# breaks-if: the pbpaste watchdog or its timeout message is removed
assert_eq "hanging pbpaste message" "The clipboard did not answer within 1 s (SUM_APP_TIMEOUT)." "$out"
# breaks-if: the running view stops falling back to the status line while there is no output
assert_contains "hanging pbpaste shows the reading status while it runs" "$running" "Reading…"
assert_eq "hanging pbpaste stops near the limit" "1" "$(( SECONDS - start < 10 ))"
assert_eq "hanging pbpaste sends nothing" "no" "$(cmd_ran)"

reset_stubs
clip "https://unreachable.example/x"
export STUB_CURL_RC=6 STUB_CURL_ERR="(6) Could not resolve host: unreachable.example"
summarize clipboard
# breaks-if: a curl failure is ignored and the empty page is summarized
assert_eq "curl failure message" "Could not fetch unreachable.example: curl: (6) Could not resolve host: unreachable.example. $HINT" "$out"
assert_eq "curl failure sends nothing" "no" "$(cmd_ran)"

reset_stubs
clip "https://slow.example/x"
export STUB_CURL_RC=28 STUB_CURL_ERR="(28) Operation timed out"
summarize clipboard
# breaks-if: curl's own timeout (exit 28) is reported as a generic fetch error
assert_eq "curl timeout message" "Fetching slow.example timed out after 15 s (SUM_FETCH_TIMEOUT). $HINT" "$out"

reset_stubs
clip "https://hang.example/x"
export STUB_CURL_HANG=1 SUM_FETCH_TIMEOUT=1
start=$SECONDS
summarize clipboard
unset SUM_FETCH_TIMEOUT
# breaks-if: the watchdog around curl is removed and a hanging fetch blocks forever
assert_eq "hanging fetch message" "Fetching hang.example timed out after 1 s (SUM_FETCH_TIMEOUT). $HINT" "$out"
# breaks-if: fetch_page stops setting the "Fetching <host>…" status
assert_contains "hanging fetch shows the host while it runs" "$running" "Fetching hang.example…"
assert_eq "hanging fetch stops near the limit" "1" "$(( SECONDS - start < 10 ))"
assert_eq "hanging fetch sends nothing" "no" "$(cmd_ran)"

reset_stubs
cp "$FIXTURES/article.html" "$STUB_PAGE"
clip "https://example.com/missing"
export STUB_HTTP_CODE=404
summarize clipboard
# breaks-if: the HTTP status check is removed and an error page is summarized
assert_eq "HTTP error message" "example.com answered with HTTP 404. $HINT" "$out"
assert_eq "HTTP error sends nothing" "no" "$(cmd_ran)"

reset_stubs
printf '%%PDF-1.7 binary' >"$STUB_PAGE"
export STUB_CTYPE="application/pdf"
clip "https://example.com/file.pdf"
summarize clipboard
# breaks-if: non-text responses are run through the HTML converter
assert_eq "non-text response message" "example.com sent application/pdf, not a web page. $HINT" "$out"

for ctype in "text/css" "text/javascript; charset=utf-8" "text/plainfoo" "text/markdownfoo"; do
  reset_stubs
  printf '%s' "$(printf 'body { color: red; } %.0s' $(seq 1 20))" >"$STUB_PAGE"
  export STUB_CTYPE="$ctype"
  clip "https://example.com/asset"
  summarize clipboard
  # breaks-if: every text/* type is summarized, not only text/plain and text/markdown
  assert_eq "$ctype response message" "example.com sent ${ctype%%;*}, not a web page. $HINT" "$out"
  assert_eq "$ctype response sends nothing" "no" "$(cmd_ran)"
done

reset_stubs
cp "$FIXTURES/article.html" "$STUB_PAGE"
clip "https://example.com/broken"
export SUM_TEXTUTIL=/usr/bin/false
summarize clipboard
unset SUM_TEXTUTIL
# breaks-if: a failed textutil is reported as a page with too little text
assert_eq "conversion failure message" "Could not convert the page at example.com to text. $HINT" "$out"
assert_eq "conversion failure sends nothing" "no" "$(cmd_ran)"

reset_stubs
cp "$FIXTURES/article.html" "$STUB_PAGE"
clip "https://example.com/slow-convert"
printf 'sleep 30\n' >"$STUBS/textutil-hang"
export SUM_TEXTUTIL="/bin/bash $STUBS/textutil-hang" SUM_FETCH_TIMEOUT=1
start=$SECONDS
summarize clipboard
unset SUM_TEXTUTIL SUM_FETCH_TIMEOUT
# breaks-if: a textutil timeout (124) is reported as a generic conversion failure or as too little text
assert_eq "conversion timeout message" \
  "Converting the page at example.com timed out after 1 s (SUM_FETCH_TIMEOUT). $HINT" "$out"
assert_eq "conversion timeout stops near the limit" "1" "$(( SECONDS - start < 10 ))"
assert_eq "conversion timeout sends nothing" "no" "$(cmd_ran)"

# The 200-character floor, counted on plain text so the count is exact.
reset_stubs
export STUB_CTYPE="text/plain"
clip "https://example.com/short"
printf '%s' "$(printf 'a%.0s' $(seq 1 199))" >"$STUB_PAGE"
summarize clipboard
# breaks-if: MIN_PAGE_CHARS drops below 200 or the check goes
assert_eq "199 characters is too little" "The page at example.com has too little text to summarize (199 characters). $HINT" "$out"
assert_eq "too little text sends nothing" "no" "$(cmd_ran)"
reset_stubs
export STUB_CTYPE="text/plain"
clip "https://example.com/enough"
printf '%s' "$(printf 'a%.0s' $(seq 1 200))" >"$STUB_PAGE"
summarize clipboard
assert_eq "200 characters is enough" "yes" "$(cmd_ran)"

reset_stubs
printf '<html><body><script>%s</script><p>Hi.</p></body></html>' "$(printf 'x%.0s' $(seq 1 500))" >"$STUB_PAGE"
clip "https://example.com/js-app"
summarize clipboard
# breaks-if: strip-html stops removing script tags before the length check
assert_eq "script-only page is too little text" \
  "The page at example.com has too little text to summarize (3 characters). $HINT" "$out"

# ===================================================== active window: browsers

reset_stubs
window_app com.apple.Safari Safari
osa_out $'https://example.com/a\nA page title\npage\n  Body of the page.\nMore body.\n'
summarize window
script=$(cat "$STUBS/last.applescript")
assert_contains "Safari: script targets Safari" "$script" 'tell application id "com.apple.Safari"'
assert_contains "Safari: uses do JavaScript" "$script" "do JavaScript"
assert_contains "Safari: reads the current tab" "$script" "current tab of front window"
assert_contains "Safari: JavaScript reads the selection first" "$script" "window.getSelection()"
assert_contains "Safari: JavaScript falls back to the page text" "$script" "document.body.innerText"
assert_eq "Safari: page text with title and URL" $'Title: A page title\nURL: https://example.com/a\n\nBody of the page.\nMore body.' "$(cat "$STUBS/cmd.stdin")"
assert_contains "Safari: summary shown" "$out" "TL;DR: stub summary."

for pair in "com.google.Chrome|Google Chrome" "com.brave.Browser|Brave Browser"; do
  reset_stubs
  IFS='|' read -r id name <<<"$pair"
  window_app "$id" "$name"
  osa_out $'https://example.com/b\nTab title\npage\nChromium page body.\n'
  summarize window
  script=$(cat "$STUBS/last.applescript")
  assert_contains "$name: script targets its bundle id" "$script" "tell application id \"$id\""
  assert_contains "$name: uses execute javascript" "$script" "execute t javascript"
  assert_contains "$name: reads the active tab" "$script" "active tab of front window"
  assert_eq "$name: page text with title and URL" $'Title: Tab title\nURL: https://example.com/b\n\nChromium page body.' "$(cat "$STUBS/cmd.stdin")"
done

reset_stubs
window_app com.google.Chrome "Google Chrome"
osa_out $'https://example.com/c\nTab\nselection\n  Only the selected words.  \n'
summarize window
# breaks-if: the selection is wrapped in the page's title and URL, or ignored
assert_eq "selection is sent alone" "Only the selected words." "$(cat "$STUBS/cmd.stdin")"

reset_stubs
window_app com.apple.Safari Safari
osa_out "none"
summarize window
# breaks-if: a browser with no window is read as an empty page and sent
assert_eq "no browser window message" "Nothing to summarize." "$out"
assert_eq "no browser window sends nothing" "no" "$(cmd_ran)"

reset_stubs
window_app com.apple.Safari Safari
osa_out $'https://example.com/blank\nBlank\npage\n   \n'
summarize window
# breaks-if: a browser page with only whitespace is sent to the command
assert_eq "empty page message" "Nothing to summarize." "$out"
assert_eq "empty page sends nothing" "no" "$(cmd_ran)"

# ===================================================== active window: Mail

reset_stubs
window_app com.apple.mail Mail
osa_out $'1\nQuarterly numbers\nAda <ada@example.com>\nHello team,\n\nthe numbers are in.\n'
summarize window
assert_contains "Mail: script asks for the selection" "$(cat "$STUBS/last.applescript")" "set sel to selection"
assert_eq "Mail: subject, sender and body" $'Subject: Quarterly numbers\nFrom: Ada <ada@example.com>\n\nHello team,\n\nthe numbers are in.' "$(cat "$STUBS/cmd.stdin")"

reset_stubs
window_app com.apple.mail Mail
osa_out "many"
summarize window
# breaks-if: several selected messages are summarized instead of refused
assert_eq "Mail: several selected" "Select one message in Mail. More than one is selected." "$out"
assert_eq "Mail: several selected sends nothing" "no" "$(cmd_ran)"

reset_stubs
window_app com.apple.mail Mail
osa_out "0"
summarize window
# breaks-if: Mail with no selected message is read as an empty message and sent
assert_eq "Mail: nothing selected" "Nothing to summarize." "$out"
assert_eq "Mail: nothing selected sends nothing" "no" "$(cmd_ran)"

reset_stubs
window_app com.apple.mail Mail
osa_out $'1\nNo body\nBob <bob@example.com>\n  \n'
summarize window
# breaks-if: a Mail message with a blank body is sent with only its headers
assert_eq "Mail: empty body" "Nothing to summarize." "$out"

# ===================================================== active window: refused apps

for pair in "org.mozilla.firefox|Firefox" "com.apple.Notes|Notes" "com.apple.Safari.TechnologyPreview|Safari Technology Preview"; do
  reset_stubs
  IFS='|' read -r id name <<<"$pair"
  window_app "$id" "$name"
  summarize window
  # breaks-if: the allowlist in app_kind grows, or matches by prefix
  assert_eq "$name: refused" "Not supported in $name." "$out"
  refute_contains "$name: no AppleScript" "$calls" "osascript"
  assert_eq "$name: nothing sent to the command" "no" "$(cmd_ran)"
done

reset_stubs
window_app com.example.Unnamed ""
summarize window
# breaks-if: read_window stops naming the app by its bundle id when it has no name
assert_eq "app without a name is named by its bundle id" "Not supported in com.example.Unnamed." "$out"

reset_stubs
window_app "" ""
front "" ""
summarize window
# breaks-if: read_window stops refusing when there is no front app
assert_eq "no front app at all" "Nothing to summarize." "$out"
assert_eq "no front app sends nothing" "no" "$(cmd_ran)"
# breaks-if: front_app passes an empty ASN on to `lsappinfo info`
refute_contains "no front app skips lsappinfo info" "$calls" "lsappinfo info"

reset_stubs
unset sum_app_id sum_app_name
front com.apple.Safari Safari
osa_out $'https://example.com/d\nT\npage\nFallback body.\n'
summarize window
# breaks-if: read_window stops asking lsappinfo when the Script Filter passed no app
assert_contains "without the passed app, lsappinfo decides" "$calls" "lsappinfo front"
assert_contains "without the passed app, Safari is read" "$(cat "$STUBS/last.applescript")" "com.apple.Safari"

# ===================================================== active window: AppleScript errors

reset_stubs
window_app com.google.Chrome "Google Chrome"
export STUB_OSA_ERR="execution error: Google Chrome got an error: Executing JavaScript through AppleScript is turned off. To turn it on, from the menu bar, go to View > Developer > Allow JavaScript from Apple Events. (12)"
summarize window
# breaks-if: the JavaScript-setting check in apple_error is removed
assert_eq "Chrome JavaScript off" "Google Chrome does not allow JavaScript from Apple Events. Turn on View > Developer > Allow JavaScript from Apple Events." "$out"
assert_eq "Chrome JavaScript off sends nothing" "no" "$(cmd_ran)"

reset_stubs
window_app com.brave.Browser "Brave Browser"
export STUB_OSA_ERR="Ausführungsfehler: Das Ausführen von JavaScript über AppleScript ist deaktiviert. (12)"
summarize window
# breaks-if: apple_error matches whole English sentences instead of JavaScript plus AppleScript
assert_eq "Brave JavaScript off, German message" "Brave Browser does not allow JavaScript from Apple Events. Turn on View > Developer > Allow JavaScript from Apple Events." "$out"

reset_stubs
window_app com.brave.Browser "Brave Browser"
export STUB_OSA_ERR="Ausführungsfehler: JavaScript über Apple-Events ist deaktiviert. (12)"
summarize window
# breaks-if: apple_error stops matching the hyphenated "Apple-Event" spelling
assert_eq "Brave JavaScript off, hyphenated Apple-Events" "Brave Browser does not allow JavaScript from Apple Events. Turn on View > Developer > Allow JavaScript from Apple Events." "$out"

reset_stubs
window_app com.google.Chrome "Google Chrome"
export STUB_OSA_ERR="Ausführungsfehler: JavaScript über Apple-Events ist deaktiviert. (12)"
summarize window
# breaks-if: apple_error stops matching the hyphenated "Apple-Event" spelling
assert_eq "Chrome JavaScript off, hyphenated Apple-Events" "Google Chrome does not allow JavaScript from Apple Events. Turn on View > Developer > Allow JavaScript from Apple Events." "$out"

reset_stubs
window_app com.apple.Safari Safari
export STUB_OSA_ERR="execution error: Safari got an error: You must enable the 'Allow JavaScript from Apple Events' option in Safari's Develop menu to use 'do JavaScript'. (8)"
summarize window
# breaks-if: Safari gets the Chromium menu path
assert_eq "Safari JavaScript off" "Safari does not allow JavaScript from Apple Events. Turn on Develop > Developer Settings > Allow JavaScript from Apple Events." "$out"

reset_stubs
window_app com.apple.mail Mail
export STUB_OSA_ERR="71:75: execution error: Keine Berechtigung zum Senden von Apple-Events an Mail. (-1743)"
summarize window
# breaks-if: the -1743 check is removed or matched on English words
assert_eq "Automation denied" "Alfred may not control Mail. Allow it under System Settings > Privacy & Security > Automation." "$out"
assert_eq "Automation denied sends nothing" "no" "$(cmd_ran)"

reset_stubs
window_app com.apple.Safari Safari
export STUB_OSA_ERR="execution error: Safari got an error: Can't get window 1. (-1719)"
summarize window
# breaks-if: apple_error drops the original error text for errors it does not recognize
assert_eq "other AppleScript error" "Could not read Safari: execution error: Safari got an error: Can't get window 1. (-1719)" "$out"

reset_stubs
window_app com.apple.Safari Safari
export STUB_OSA_HANG=1 SUM_APP_TIMEOUT=1
start=$SECONDS
summarize window
unset SUM_APP_TIMEOUT
# breaks-if: the watchdog around osascript is removed
assert_eq "hanging app" "Safari did not answer within 1 s (SUM_APP_TIMEOUT)." "$out"
# breaks-if: read_browser stops setting the "Reading <app>…" status
assert_contains "hanging app shows the app while it runs" "$running" "Reading Safari…"
assert_eq "hanging app stops near the limit" "1" "$(( SECONDS - start < 10 ))"

# ===================================================== size limit

reset_stubs
export SUM_MAX_CHARS=50
s50=$(printf 'ä%.0s' $(seq 1 50))
clip "$s50"
summarize clipboard
assert_eq "exactly SUM_MAX_CHARS is sent whole" "$s50" "$(cat "$STUBS/cmd.stdin")"
refute_contains "exactly SUM_MAX_CHARS has no cut notice" "$out" "Input cut"
reset_stubs
clip "${s50}b"
summarize clipboard
# breaks-if: the cut in run_command is removed or goes off by one
assert_eq "one more is cut to SUM_MAX_CHARS" "$s50" "$(cat "$STUBS/cmd.stdin")"
assert_contains "the cut is stated" "$out" "Input cut to 50 characters (SUM_MAX_CHARS)."
assert_contains "the summary follows the notice" "$out" "TL;DR: stub summary."
unset SUM_MAX_CHARS

reset_stubs
clip "Longer text"
export STUB_CMD_MODE=hang SUM_TIMEOUT=1 SUM_MAX_CHARS=4
summarize clipboard
unset SUM_TIMEOUT SUM_MAX_CHARS
# breaks-if: the running view stops showing the cut notice
assert_contains "the cut is stated while the command runs" "$running" $'Input cut to 4 characters (SUM_MAX_CHARS).\n\nSummarizing…'

# ===================================================== the command

reset_stubs
clip "Text"
export STUB_CMD_MODE=fail
summarize clipboard
# breaks-if: a non-zero exit is shown as an empty or successful summary
assert_eq "command failure" $'The command failed with exit code 3.\nstub: not logged in' "$out"
refute_contains "no login hint for another command" "$out" "Run \`claude\`"

# The command's stderr in the message stops at 2000 characters.
printf 'printf "%%s" "$STUB_ERR" >&2\nexit 3\n' >"$STUBS/errout"
e2000=$(printf 'e%.0s' $(seq 1 2000))
reset_stubs
clip "Text"
STUB_ERR="$e2000" SUM_COMMAND="/bin/bash $STUBS/errout" summarize clipboard
# breaks-if: the cut on the command's stderr drops below 2000 characters
assert_eq "2000 characters of stderr are shown whole" $'The command failed with exit code 3.\n'"$e2000" "$out"
reset_stubs
clip "Text"
STUB_ERR="${e2000}X" SUM_COMMAND="/bin/bash $STUBS/errout" summarize clipboard
# breaks-if: the cut on the command's stderr is removed or goes off by one
assert_eq "2001 characters of stderr are cut to 2000" $'The command failed with exit code 3.\n'"$e2000" "$out"

ZDIR="$STUBS/zdotdir"
ZHOME="$STUBS/zhome"
mkdir -p "$ZDIR" "$ZHOME"
printf 'claude() { /bin/bash "%s/cmd" "$@"; }\n' "$STUBS" >"$ZDIR/.zshenv"
reset_stubs
clip "Text"
export STUB_CMD_MODE=fail
HOME="$ZHOME" ZDOTDIR="$ZDIR" SUM_COMMAND='claude -p --model "$SUM_MODEL"' summarize clipboard
# breaks-if: the login hint is dropped, or keyed to something other than the first word
assert_eq "claude failure adds the login hint" $'The command failed with exit code 3.\nstub: not logged in\nRun `claude` once in a terminal to log in, or update `claude` if it rejected an option.' "$out"

reset_stubs
clip "Text"
HOME="$ZHOME" ZDOTDIR="$ZDIR" SUM_COMMAND='claude -p' summarize clipboard
assert_contains "claude as first word reaches the stub (zsh function)" "$out" "TL;DR: stub summary."

reset_stubs
clip "Text"
SUM_COMMAND="printf 'TL;DR: x.\n\n- ![x](http://127.0.0.1:8000/probe) <img src=\"http://127.0.0.1:8000/p\">\n'" summarize clipboard
# breaks-if: summarize.sh renders the command's output without the view helpers' cleanup
assert_eq "an image in the command's output is never shown as one" $'TL;DR: x.\n\n- [image: x]' "$out"

# shellcheck source=scripts/summarize.sh
( source "$SCRIPT"
  # breaks-if: command_name stops removing the quotes around the first word
  for pair in "claude -p|claude" "/opt/homebrew/bin/claude -p|claude" "  claude|claude" \
      '"/opt/x/claude" -p|claude' '"claude" -p|claude' \
      "claude-wrapper -p|claude-wrapper" "llm -m x|llm" "echo claude|echo"; do
    SUM_COMMAND="${pair%%|*}"
    [ "$(command_name)" = "${pair#*|}" ] && echo ok || echo "FAIL: command_name [$SUM_COMMAND] gave [$(command_name)]"
  done ) >"$STUBS/names"
assert_eq "command_name picks the first word without its directory" "0" "$(grep -c FAIL "$STUBS/names")"
assert_eq "command_name cases all ran and passed" "8" "$(grep -c '^ok$' "$STUBS/names")"

reset_stubs
clip "Text"
export STUB_CMD_MODE=hang SUM_TIMEOUT=1
start=$SECONDS
summarize clipboard
unset SUM_TIMEOUT
# breaks-if: the watchdog around the command is removed
assert_eq "command timeout" "The command timed out after 1 s (SUM_TIMEOUT)." "$out"
# breaks-if: run_command stops setting the "Summarizing…" status
assert_contains "a silent command shows the summarizing status" "$running" "Summarizing…"
assert_eq "command timeout stops near the limit" "1" "$(( SECONDS - start < 10 ))"
sleep 0.2
pid=$(cat "$STUBS/cmd.pid" 2>/dev/null)
if [ -z "$pid" ]; then
  not_ok "the hanging command never recorded its pid"
elif kill -0 "$pid" 2>/dev/null; then
  not_ok "a timed-out command should be killed"
else
  ok
fi

reset_stubs
clip "Text"
export STUB_CMD_MODE=empty
summarize clipboard
# breaks-if: an empty answer from the command shows an empty window
assert_eq "empty answer" "The command returned no summary." "$out"

# ===================================================== streaming

cat >"$STUBS/slow" <<'STUB'
cat >/dev/null
printf 'TL;DR: first part arrived.\n'
sleep 1
printf -- '- second part\n'
STUB
reset_stubs
clip "Text"
SUM_COMMAND="/bin/bash $STUBS/slow" summarize clipboard
# breaks-if: running renders stop showing the output so far
assert_contains "partial output shown while running" "$running" "TL;DR: first part arrived."
early=$(printf '%s' "$running" | awk 'BEGIN { RS = "---" } /first part arrived/ && !/second part/ { f = 1 } END { print f + 0 }')
assert_eq "a render showed the first part before the second existed" "1" "$early"
assert_eq "final shows everything" $'TL;DR: first part arrived.\n- second part' "$out"
assert_eq "several renders while it streamed" "1" "$(( renders > 2 ))"

# ===================================================== isolation and repetition

reset_stubs
clip "Same input"
summarize clipboard
pwd1=$(cat "$STUBS/cmd.pwd")
stdin1=$(cat "$STUBS/cmd.stdin")
assert_eq "command dir was empty" "" "$(cat "$STUBS/cmd.ls")"
refute_contains "command dir is not the workflow dir" "$pwd1" "$ROOT"
refute_contains "command dir is not the job dir" "$pwd1" "$JOBS"
# breaks-if: finish stops removing the command's temp directory
refute_file "command dir removed afterwards" "$pwd1"
reset_stubs
clip "Same input"
summarize clipboard
assert_eq "second run: same stdin" "$stdin1" "$(cat "$STUBS/cmd.stdin")"
assert_eq "second run: no job left behind" "0" "$(jobs_left)"
refute_file "second run: its command dir removed too" "$(cat "$STUBS/cmd.pwd")"

# A new start stops a job whose Text View was closed mid-run.
reset_stubs
clip "Text"
export STUB_CMD_MODE=hang
old=$(sum_job="" bash "$SCRIPT" clipboard | json_get '$d->{variables}{sum_job}')
for _ in $(seq 1 50); do [ -s "$STUBS/cmd.pid" ] && break; sleep 0.1; done
old_pid=$(cat "$STUBS/cmd.pid" 2>/dev/null)
assert_eq "the old job's command recorded its pid" "yes" "$([ -n "$old_pid" ] && echo yes || echo no)"
unset STUB_CMD_MODE
rm -f "$STUBS/cmd.pid"
summarize clipboard
sleep 0.3
# breaks-if: stop_old_jobs is no longer called when a job starts
if [ -z "$old_pid" ]; then
  not_ok "the old job's command never recorded its pid"
elif kill -0 "$old_pid" 2>/dev/null; then
  not_ok "starting a job should stop the old job's command"
  kill "$old_pid" 2>/dev/null
else
  ok
fi
refute_file "old job directory removed" "$old"
assert_contains "new job still runs" "$out" "TL;DR: stub summary."

# fake_job NAME BODY: a stand-in job in $JOBS/NAME, started like start_job
# starts one, in a process group of its own. Its command line ends in
# "summarize.sh --run DIR", so the script takes it for the job in DIR. BODY
# is bash code and touches $FAKE_OUT/ready once its traps are set. Sets
# fake_pid. Started from a subshell, so the fake is not a child of the test
# shell: it never lingers as a zombie, and bash prints no notice when it
# gets killed.
export FAKE_OUT="$STUBS/fake"
fake_job() {
  rm -rf "$FAKE_OUT"
  mkdir -p "$FAKE_OUT" "$JOBS/$1"
  printf '%s\n' "$2" >"$FAKE_OUT/summarize.sh"
  fake_pid=$(/usr/bin/perl -e 'setpgrp(0, 0); exec @ARGV' /bin/bash "$FAKE_OUT/summarize.sh" --run "$JOBS/$1" \
    </dev/null >/dev/null 2>&1 & echo $!)
  printf '%s\n' "$fake_pid" >"$JOBS/$1/pid"
  for _ in $(seq 1 50); do [ -e "$FAKE_OUT/ready" ] && break; sleep 0.1; done
  [ -e "$FAKE_OUT/ready" ] || not_ok "fake job $1 never signalled ready"
}
fake_alive() {
  case "$(ps -ww -o command= -p "$fake_pid" 2>/dev/null)" in
    *"summarize.sh --run"*) return 0 ;;
  esac
  return 1
}

# A stopped job still writes into its directory while it ends, the way
# finish does. The directory goes only after that.
reset_stubs
clip "Text"
fake_job job.slow 'trap '\''sleep 0.5; [ -d "$2" ] && echo yes >"$FAKE_OUT/saw-dir"; exit 143'\'' TERM
: >"$FAKE_OUT/ready"
while :; do sleep 0.1; done'
summarize clipboard
# breaks-if: stop_old_jobs removes the directory right after the TERM instead of waiting for the job to end
assert_eq "a stopped job still had its directory while it ended" "yes" "$(cat "$FAKE_OUT/saw-dir" 2>/dev/null)"
# breaks-if: stop_old_jobs skips the rm once it has waited for the job
refute_file "the stopped job's directory removed afterwards" "$JOBS/job.slow"
assert_contains "new job runs after waiting" "$out" "TL;DR: stub summary."
kill -KILL -- "-$fake_pid" 2>/dev/null

# A job that ignores the TERM gets a KILL once the wait is over.
reset_stubs
clip "Text"
fake_job job.deaf 'trap "" TERM
: >"$FAKE_OUT/ready"
while :; do sleep 0.1; done'
start=$SECONDS
summarize clipboard
# breaks-if: stop_old_jobs drops the KILL for a job still running after the wait
if fake_alive; then
  not_ok "a job that ignores TERM should be killed"
  kill -KILL -- "-$fake_pid" 2>/dev/null
else
  ok
fi
# breaks-if: stop_old_jobs waits without a bound for a job that ignores TERM
assert_eq "the wait for a stopped job is bounded" "1" "$(( SECONDS - start < 15 ))"
# breaks-if: stop_old_jobs keeps the directory of a job it had to KILL
refute_file "the killed job's directory removed" "$JOBS/job.deaf"
assert_contains "new job runs after a killed one" "$out" "TL;DR: stub summary."

# A backend that ignores TERM, in a group of its own under a job that is
# stuck, does not outlive the next start.
reset_stubs
clip "Text"
bk="$STUBS/backend-ran"
rm -f "$bk"
fake_job job.backend 'trap "" TERM
/usr/bin/perl -e '\''setpgrp(0, 0); $SIG{TERM} = "IGNORE"; open F, ">", $ARGV[0]; print F "$$\n"; close F; $0 = "deaf-backend"; sleep 60'\'' "$FAKE_OUT/backend.pid" &
: >"$FAKE_OUT/ready"
while :; do sleep 0.1; done'
for _ in $(seq 1 50); do [ -s "$FAKE_OUT/backend.pid" ] && break; sleep 0.1; done
backend_pid=$(cat "$FAKE_OUT/backend.pid" 2>/dev/null)
printf '%s\n' "$backend_pid" >"$JOBS/job.backend/backend.pgid"
summarize clipboard
sleep 0.3
# breaks-if: stop_old_jobs stops signalling the backend group recorded in backend.pgid
if [ -z "$backend_pid" ]; then
  not_ok "the backend never recorded its pid"
elif kill -0 "$backend_pid" 2>/dev/null; then
  not_ok "a backend that ignores TERM should be gone after the next start"
  kill -KILL "$backend_pid" 2>/dev/null
else
  ok
fi
kill -KILL -- "-$fake_pid" 2>/dev/null

# A recorded group with no process left, and a garbage record, make
# stop_old_jobs neither fail nor signal anything.
reset_stubs
clip "Text"
mkdir -p "$JOBS/job.gone" "$JOBS/job.junk"
printf '%s\n' 999999 >"$JOBS/job.gone/backend.pgid"
printf '%s\n' '-1' >"$JOBS/job.junk/backend.pgid"
/usr/bin/perl -e 'setpgrp(0, 0); exec @ARGV' sleep 30 &
bystander=$!
printf '%s\n' "$bystander" >"$JOBS/job.gone/pid"
summarize clipboard
assert_contains "new job runs despite stale pgid records" "$out" "TL;DR: stub summary."
# breaks-if: kill_backend signals a record that is not a plain positive group id
if kill -0 "$bystander" 2>/dev/null; then
  ok
  kill "$bystander" 2>/dev/null
else
  not_ok "a stale or garbage backend.pgid should not signal anything"
fi
refute_file "job with a gone group removed" "$JOBS/job.gone"
refute_file "job with a junk record removed" "$JOBS/job.junk"

# A finished job's pid is never signalled, even if a process that looks
# like that job holds it.
reset_stubs
clip "Text"
fake_job job.done ': >"$FAKE_OUT/ready"
while :; do sleep 0.1; done'
: >"$JOBS/job.done/done"
summarize clipboard
# breaks-if: stop_old_jobs drops the `! -e done` guard and signals the pid of a finished job
if fake_alive; then
  ok
else
  not_ok "the pid of a finished job should not be signalled"
fi
kill -KILL -- "-$fake_pid" 2>/dev/null
# breaks-if: stop_old_jobs keeps the directory of a finished job it did not signal
refute_file "a finished job's directory removed" "$JOBS/job.done"

# A stale job whose pid now belongs to another process group: that group
# survives, and the stale directory still goes.
reset_stubs
clip "Text"
mkdir -p "$JOBS/job.stale"
/usr/bin/perl -e 'setpgrp(0, 0); exec @ARGV' sleep 30 &
other_pid=$!
printf '%s\n' "$other_pid" >"$JOBS/job.stale/pid"
summarize clipboard
# breaks-if: stop_old_jobs kills the pid in a stale job directory without checking what runs there
if kill -0 "$other_pid" 2>/dev/null; then
  ok
  kill "$other_pid" 2>/dev/null
else
  not_ok "a stale job's pid should not be killed when another process holds it"
fi
wait "$other_pid" 2>/dev/null
refute_file "stale job directory removed" "$JOBS/job.stale"
assert_contains "new job runs after a stale one" "$out" "TL;DR: stub summary."

# render_until_final JOB: reruns the Text View for JOB like Alfred, at most
# 50 times. Sets out (last response) and head ("rerun|sum_job").
render_until_final() {
  local json fields
  for _ in $(seq 1 50); do
    json=$(sum_job="$1" bash "$SCRIPT" clipboard 2>/dev/null)
    fields=$(printf '%s' "$json" | render_fields)
    head=${fields%%$'\n'*}
    [ "${head%%|*}" = "-" ] && break
    sleep 0.1
  done
  out=${fields#*$'\n'}
}

# A job killed before it could write done ends the view with a message.
reset_stubs
clip "Text"
export STUB_CMD_MODE=hang
job=$(sum_job="" bash "$SCRIPT" clipboard | json_get '$d->{variables}{sum_job}')
for _ in $(seq 1 50); do [ -s "$STUBS/cmd.pid" ] && break; sleep 0.1; done
unset STUB_CMD_MODE
echo "last words of the job" >>"$job/job.err"
kill -KILL -- "-$(cat "$job/pid")" 2>/dev/null
cmd_pid=$(cat "$STUBS/cmd.pid" 2>/dev/null)
if [ -n "$cmd_pid" ]; then
  kill -KILL -- "-$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
else
  not_ok "the hanging command never recorded its pid"
fi
render_until_final "$job"
# breaks-if: render only looks for done and reruns forever for a job that died without it
assert_eq "a killed job stops the reruns" "-|" "$head"
assert_contains "a killed job ends with a message" "$out" "Summarize stopped unexpectedly."
# breaks-if: render drops the tail of job.err from the message of a killed job
assert_contains "the message carries the job's stderr" "$out" "last words of the job"
# breaks-if: render skips the rm -rf for a job that was killed before it wrote done
refute_file "a killed job's directory removed" "$job"

# A job whose pid now runs something else is dead too, and that process
# is left alone.
reset_stubs
mkdir -p "$JOBS/job.reused"
echo "reused stderr" >"$JOBS/job.reused/job.err"
/usr/bin/perl -e 'setpgrp(0, 0); exec @ARGV' sleep 30 &
other_pid=$!
printf '%s\n' "$other_pid" >"$JOBS/job.reused/pid"
render_until_final "$JOBS/job.reused"
# breaks-if: render takes any live pid for the running job
assert_eq "a job whose pid runs something else is not rerun" "-|" "$head"
assert_contains "a job whose pid was reused ends with a message" "$out" "Summarize stopped unexpectedly."
assert_contains "the reused-pid message carries the job's stderr" "$out" "reused stderr"
# breaks-if: render signals the process that now holds a dead job's pid
if kill -0 "$other_pid" 2>/dev/null; then ok; else not_ok "render should not signal the process that now holds the pid"; fi
kill "$other_pid" 2>/dev/null
wait "$other_pid" 2>/dev/null
# breaks-if: render skips the rm -rf for a job whose pid now belongs to another process
refute_file "a reused-pid job's directory removed" "$JOBS/job.reused"

# A job directory without a pid, left by a start that failed before it
# wrote one, counts as dead too.
reset_stubs
mkdir -p "$JOBS/job.nopid"
echo "no pid stderr" >"$JOBS/job.nopid/job.err"
render_until_final "$JOBS/job.nopid"
# breaks-if: job_running treats a missing or empty pid as a running job
assert_eq "a job without a pid file is not rerun" "-|" "$head"
assert_contains "a job without a pid file ends with a message" "$out" "Summarize stopped unexpectedly."
# breaks-if: render skips the rm -rf for a job that has no pid file
refute_file "a pid-less job's directory removed" "$JOBS/job.nopid"

# A dead job that already wrote its own message keeps it.
reset_stubs
mkdir -p "$JOBS/job.hasmsg"
echo "A real failure message." >"$JOBS/job.hasmsg/msg"
echo "ignored stderr" >"$JOBS/job.hasmsg/job.err"
render_until_final "$JOBS/job.hasmsg"
# breaks-if: render writes "stopped unexpectedly" over the message of a job that died before done
assert_eq "a dead job's own message is kept" "A real failure message." "$out"
# breaks-if: render skips the rm -rf for a dead job that already wrote its own message
refute_file "a dead job with a message leaves no directory" "$JOBS/job.hasmsg"

# ===================================================== content on disk

# run_job_alone SOURCE: runs one job to its end with no Text View, the way
# a job runs on after its view was closed. Sets job.
run_job_alone() {
  job="$JOBS/job.alone"
  rm -rf "$job"
  mkdir -p "$job"
  printf '%s\n' "$1" >"$job/source"
  bash "$SCRIPT" --run "$job" 2>>"$job/job.err"
}

# refute_content LABEL: no file that holds the text the job read, error
# output from reading it, or a status line naming the fetched host, is left
# in $job.
refute_content() {
  local f
  for f in clip pbpaste.err page curl.err osa.err input input.cut err status; do
    refute_file "$1: no $f left" "$job/$f"
  done
}

reset_stubs
clip "Secret clipboard text"
run_job_alone clipboard
# breaks-if: finish or run_command stops deleting clip, pbpaste.err, input or err
refute_content "finished text job"
assert_file "finished text job keeps out" "$job/out"
assert_file "finished text job wrote done" "$job/done"
render_until_final "$job"
assert_contains "finished text job still shows the summary" "$out" "TL;DR: stub summary."
refute_file "finished text job's directory removed by render" "$job"

reset_stubs
export SUM_MAX_CHARS=3
clip "Longer than three"
run_job_alone clipboard
unset SUM_MAX_CHARS
# breaks-if: the cut text or the cut notice no longer survives the early deletion
refute_content "cut job"
render_until_final "$job"
assert_contains "cut job still shows the cut notice" "$out" "Input cut to 3 characters (SUM_MAX_CHARS)."
assert_eq "cut job sent the cut text" "Lon" "$(cat "$STUBS/cmd.stdin")"

reset_stubs
cp "$FIXTURES/article.html" "$STUB_PAGE"
clip "https://example.com/tide-pools"
run_job_alone clipboard
# breaks-if: drop_content leaves the downloaded page or curl's stderr behind
refute_content "finished URL job"
assert_contains "finished URL job sent the page text" "$(cat "$STUBS/cmd.stdin")" "Volunteers counted"

reset_stubs
window_app com.apple.mail Mail
osa_out $'1\nPrivate subject\nAda <ada@example.com>\nPrivate mail body.\n'
run_job_alone window
# breaks-if: the mail body stays in the job directory after the job
refute_content "finished Mail job"
assert_eq "finished Mail job sent the body" $'Subject: Private subject\nFrom: Ada <ada@example.com>\n\nPrivate mail body.' "$(cat "$STUBS/cmd.stdin")"

reset_stubs
clip "https://unreachable.example/x"
export STUB_CURL_RC=6 STUB_CURL_ERR="(6) Could not resolve host: unreachable.example"
run_job_alone clipboard
# breaks-if: finish stops calling drop_content, so a job that fails before the command keeps clip and curl.err
refute_content "failed fetch"
render_until_final "$job"
# breaks-if: curl.err is deleted before fail builds its message from it
assert_eq "failed fetch still shows its message" \
  "Could not fetch unreachable.example: curl: (6) Could not resolve host: unreachable.example. $HINT" "$out"

reset_stubs
window_app com.apple.mail Mail
export STUB_OSA_ERR="execution error: not allowed (-1743)"
run_job_alone window
# breaks-if: finish stops calling drop_content, so osascript's stderr stays behind
refute_content "denied Automation"
render_until_final "$job"
# breaks-if: osa.err is deleted before apple_error reads it, so the denial shows as a generic failure
assert_eq "denied Automation still shows its message" \
  "Alfred may not control Mail. Allow it under System Settings > Privacy & Security > Automation." "$out"

reset_stubs
window_app org.mozilla.firefox Firefox
run_job_alone window
# breaks-if: finish fails on content files that were never written
refute_content "unsupported app"
assert_file "unsupported app wrote done" "$job/done"
render_until_final "$job"
# breaks-if: finish removes or overwrites msg, so the not-supported message is lost
assert_eq "unsupported app still shows its message" "Not supported in Firefox." "$out"

reset_stubs
clip "Text"
export STUB_CMD_MODE=fail
run_job_alone clipboard
# breaks-if: finish stops deleting err, the command's stderr
refute_content "failed command"
render_until_final "$job"
# breaks-if: err is deleted before run_command copies it into msg
assert_eq "failed command still shows its stderr" $'The command failed with exit code 3.\nstub: not logged in' "$out"

# The input is gone while the command still runs.
reset_stubs
clip "Text read while running"
export STUB_CMD_MODE=hang
job=$(sum_job="" bash "$SCRIPT" clipboard | json_get '$d->{variables}{sum_job}')
for _ in $(seq 1 50); do [ -s "$STUBS/cmd.pid" ] && break; sleep 0.1; done
unset STUB_CMD_MODE
# breaks-if: run_command keeps input until the command ends instead of deleting it once stdin is open
refute_file "running job: input already gone" "$job/input"
refute_file "running job: clip already gone" "$job/clip"
# breaks-if: run_command deletes input before the command has it open as stdin, so the command reads nothing
assert_eq "running job: the command still got the whole input" "Text read while running" "$(cat "$STUBS/cmd.stdin")"
kill -KILL -- "-$(cat "$job/pid")" 2>/dev/null
cmd_pid=$(cat "$STUBS/cmd.pid" 2>/dev/null)
kill -KILL -- "-$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
rm -rf "$job"

# The downloaded page and curl's stderr are gone while the command still runs.
reset_stubs
cp "$FIXTURES/article.html" "$STUB_PAGE"
clip "https://example.com/tide-pools"
export STUB_CMD_MODE=hang
job=$(sum_job="" bash "$SCRIPT" clipboard | json_get '$d->{variables}{sum_job}')
for _ in $(seq 1 50); do [ -s "$STUBS/cmd.pid" ] && break; sleep 0.1; done
unset STUB_CMD_MODE
for f in page curl.err pbpaste.err input input.cut clip; do
  # breaks-if: run_command stops calling drop_content, so $f stays until the job ends
  refute_file "running URL job: $f already gone" "$job/$f"
done
kill -KILL -- "-$(cat "$job/pid")" 2>/dev/null
cmd_pid=$(cat "$STUBS/cmd.pid" 2>/dev/null)
kill -KILL -- "-$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
rm -rf "$job"

# finish and drop_content run again on a job whose files are already gone.
mkdir -p "$JOBS/job.twice"
: >"$JOBS/job.twice/out"
# shellcheck source=scripts/summarize.sh
( source "$SCRIPT"
  JOB="$JOBS/job.twice"
  { drop_content && drop_content; } || echo "drop_content failed"
  finish
  finish
  echo "ended" ) >"$STUBS/twice.out" 2>&1
# breaks-if: drop_content or finish errors when the content files are already absent
assert_eq "finish twice: no error output" "ended" "$(cat "$STUBS/twice.out")"
assert_file "finish twice: done written" "$JOBS/job.twice/done"
refute_file "finish twice: no failure message" "$JOBS/job.twice/msg"
rm -rf "$JOBS/job.twice"

# finish with a failing exit status over files that are already gone still
# writes the message and the done marker.
mkdir -p "$JOBS/job.twice"
: >"$JOBS/job.twice/out"
# shellcheck source=scripts/summarize.sh
( source "$SCRIPT"
  JOB="$JOBS/job.twice"
  drop_content
  ( exit 5 )
  finish
  echo "ended" ) >"$STUBS/twice.out" 2>&1
# breaks-if: finish skips the failure message when the content files are already absent
assert_eq "finish after drop_content, failing: no error output" "ended" "$(cat "$STUBS/twice.out")"
assert_contains "finish after drop_content, failing: names the exit code" "$(cat "$JOBS/job.twice/msg" 2>/dev/null)" "exit code 5"
assert_file "finish after drop_content, failing: done written" "$JOBS/job.twice/done"
rm -rf "$JOBS/job.twice"

# ===================================================== prompt assembly

# A setting the developer's shell exports must not reach the tests.
leaked=$(SUM_MODEL=opus sum_app_id=com.apple.Notes NPM_CONFIG_PREFIX=/x /bin/bash -c \
  'source "$1/test/helpers.sh"; source "$1/test/stubs.sh"; printf "%s|%s|%s|%s" "${SUM_MODEL-unset}" "${sum_app_id-unset}" "${NPM_CONFIG_PREFIX-unset}" "${SUM_CURL:+stubbed}"' _ "$ROOT")
# breaks-if: stubs.sh stops resetting SUM_*, sum_* and NPM_CONFIG_PREFIX from the caller's environment
assert_eq "stubs.sh drops exported SUM_*, sum_* and NPM_CONFIG_PREFIX but keeps its stubs" "unset|unset|unset|stubbed" "$leaked"

reset_stubs
clip "Text"
summarize clipboard
prompt=$(cat "$STUBS/cmd.prompt")
assert_contains "default prompt is prompt.md" "$prompt" "One line that starts with \"TL;DR:\""
assert_contains "default bullet range" "$prompt" "Between 3 and 10 bullet points"
# breaks-if: the prompt stops tying the bullet count to the text length, so a short text may get the maximum
assert_contains "default bullet count follows the text length" "$prompt" "a text of a few lines gets the fewest (3), a long article gets the most (10)"
assert_contains "default language follows the input" "$prompt" "Write in the same language as the input."
assert_contains "default prompt asks for no links or images" "$prompt" "Do not include links, images or HTML."
refute_contains "no placeholder left" "$prompt" "{"
assert_eq "default model" "sonnet" "$(cat "$STUBS/cmd.model")"

reset_stubs
clip "Text"
SUM_MIN_BULLETS=2 SUM_MAX_BULLETS=5 SUM_LANGUAGE=German SUM_MODEL=haiku summarize clipboard
prompt=$(cat "$STUBS/cmd.prompt")
assert_contains "bullet range reaches the prompt" "$prompt" "Between 2 and 5 bullet points"
# breaks-if: the length rule keeps the default 3 and 10 instead of the configured range
assert_contains "length rule uses the configured range" "$prompt" "a text of a few lines gets the fewest (2), a long article gets the most (5)"
assert_contains "language reaches the prompt" "$prompt" "Write in German."
assert_eq "model reaches the command" "haiku" "$(cat "$STUBS/cmd.model")"

reset_stubs
clip "Text"
SUM_PROMPT_OVERRIDE='Own prompt: {min_bullets}-{max_bullets} bullets in {language}.' SUM_LANGUAGE=French summarize clipboard
# breaks-if: the override is ignored or appended to prompt.md instead of replacing it
assert_eq "override replaces the bundled prompt" "Own prompt: 3-10 bullets in French." "$(cat "$STUBS/cmd.prompt")"

# ===================================================== configuration guards

for pair in "SUM_MIN_BULLETS=abc|SUM_MIN_BULLETS must be a whole number of 1 or more (got \"abc\")." \
    "SUM_MAX_BULLETS=0|SUM_MAX_BULLETS must be a whole number of 1 or more (got \"0\")." \
    "SUM_MAX_CHARS=-5|SUM_MAX_CHARS must be a whole number of 1 or more (got \"-5\")." \
    "SUM_TIMEOUT=1.5|SUM_TIMEOUT must be a whole number of 1 or more (got \"1.5\")." \
    "SUM_FETCH_TIMEOUT=007|SUM_FETCH_TIMEOUT must be a whole number of 1 or more (got \"007\")." \
    "SUM_APP_TIMEOUT=x|SUM_APP_TIMEOUT must be a whole number of 1 or more (got \"x\")." \
    "SUM_TIMEOUT=0100|SUM_TIMEOUT must be a whole number of 1 or more (got \"0100\")." \
    "SUM_MIN_BULLETS=101|SUM_MIN_BULLETS must be 100 or less (got \"101\")." \
    "SUM_MAX_BULLETS=101|SUM_MAX_BULLETS must be 100 or less (got \"101\")." \
    "SUM_MAX_CHARS=10000001|SUM_MAX_CHARS must be 10000000 or less (got \"10000001\")." \
    "SUM_TIMEOUT=100000001|SUM_TIMEOUT must be 100000000 or less (got \"100000001\")." \
    "SUM_FETCH_TIMEOUT=100000001|SUM_FETCH_TIMEOUT must be 100000000 or less (got \"100000001\")." \
    "SUM_APP_TIMEOUT=100000001|SUM_APP_TIMEOUT must be 100000000 or less (got \"100000001\")." \
    "SUM_TIMEOUT=999999999|SUM_TIMEOUT must be 100000000 or less (got \"999999999\")." \
    "SUM_MAX_BULLETS=123456789012345678901234567890|SUM_MAX_BULLETS must be 100 or less (got \"123456789012345678901234567890\")." \
    "SUM_MAX_CHARS=123456789012345678901234567890|SUM_MAX_CHARS must be 10000000 or less (got \"123456789012345678901234567890\")." \
    "SUM_APP_TIMEOUT=123456789012345678901234567890|SUM_APP_TIMEOUT must be 100000000 or less (got \"123456789012345678901234567890\")."; do
  reset_stubs
  clip "Text"
  # breaks-if: need_count stops rejecting that value, or drops its upper bound
  export "${pair%%|*}"
  summarize clipboard
  unset "${pair%%=*}"
  assert_eq "guard ${pair%%|*}" "${pair#*|}" "$out"
  assert_eq "guard ${pair%%|*} sends nothing" "no" "$(cmd_ran)"
done

# Each limit itself is allowed, and every timeout at its limit still runs
# under timeout.pl. A URL clipboard uses all three timeouts.
for setting in "SUM_MIN_BULLETS=100 SUM_MAX_BULLETS=100" SUM_MAX_CHARS=10000000 \
    SUM_TIMEOUT=100000000 SUM_FETCH_TIMEOUT=100000000 SUM_APP_TIMEOUT=100000000; do
  reset_stubs
  cp "$FIXTURES/article.html" "$STUB_PAGE"
  clip "https://example.com/tide-pools"
  # breaks-if: the upper bound in need_count is off by one, or above what timeout.pl accepts
  read -r -a vars <<<"$setting"
  export "${vars[@]}"
  summarize clipboard
  unset "${vars[@]%%=*}"
  assert_contains "limit $setting is accepted" "$out" "TL;DR: stub summary."
done

# The lowest allowed value is accepted. The timeouts at 1 are covered by the
# tests that make a command, a page or an app hang.
for setting in "SUM_MIN_BULLETS=1 SUM_MAX_BULLETS=1" SUM_MAX_CHARS=1; do
  reset_stubs
  clip "Text"
  # breaks-if: need_count moves its lower bound above 1
  read -r -a vars <<<"$setting"
  export "${vars[@]}"
  summarize clipboard
  unset "${vars[@]%%=*}"
  assert_contains "lower limit $setting is accepted" "$out" "TL;DR: stub summary."
done

# An empty setting means its default. The loop proves each empty value is
# accepted, the checks after it prove which default each one gets.
for name in SUM_MIN_BULLETS SUM_MAX_BULLETS SUM_MAX_CHARS SUM_TIMEOUT SUM_FETCH_TIMEOUT SUM_APP_TIMEOUT; do
  reset_stubs
  cp "$FIXTURES/article.html" "$STUB_PAGE"
  clip "https://example.com/tide-pools"
  # breaks-if: load_config stops applying its default to an empty setting, and need_count rejects ""
  export "$name="
  summarize clipboard
  unset "$name"
  assert_contains "empty $name is accepted" "$out" "TL;DR: stub summary."
done
reset_stubs
clip "Text"
SUM_MIN_BULLETS="" SUM_MAX_BULLETS="" summarize clipboard
assert_contains "empty bullet counts mean 3 to 10" "$(cat "$STUBS/cmd.prompt")" "Between 3 and 10"
reset_stubs
cp "$FIXTURES/article.html" "$STUB_PAGE"
clip "https://example.com/tide-pools"
SUM_FETCH_TIMEOUT="" summarize clipboard
# breaks-if: an empty SUM_FETCH_TIMEOUT stops falling back to 15 seconds
assert_contains "empty SUM_FETCH_TIMEOUT means 15 seconds" "$calls" "--max-time 15 "
reset_stubs
clip "$(/usr/bin/perl -e 'print "a" x 200001')"
SUM_MAX_CHARS="" summarize clipboard
# breaks-if: an empty SUM_MAX_CHARS stops falling back to 200000 characters
assert_contains "empty SUM_MAX_CHARS means 200000 characters" "$out" "Input cut to 200000 characters (SUM_MAX_CHARS)."

reset_stubs
clip "Text"
SUM_MIN_BULLETS=6 SUM_MAX_BULLETS=4 summarize clipboard
# breaks-if: the min-above-max check is removed
assert_eq "min above max" "SUM_MIN_BULLETS (6) is larger than SUM_MAX_BULLETS (4)." "$out"
reset_stubs
clip "Text"
SUM_MIN_BULLETS=4 SUM_MAX_BULLETS=4 summarize clipboard
assert_contains "min equal to max is fine" "$(cat "$STUBS/cmd.prompt")" "Between 4 and 4"

reset_stubs
clip "Text"
SUM_COMMAND="   " summarize clipboard
# breaks-if: a blank SUM_COMMAND runs zsh with nothing and reports an empty summary
assert_eq "blank command" "SUM_COMMAND is empty. Set it in the workflow's Configure Workflow screen." "$out"

reset_stubs
clip "Text"
SUM_COMMAND="" summarize clipboard
# breaks-if: load_config treats an empty SUM_COMMAND like an unset one and runs the default command
assert_eq "empty command" "SUM_COMMAND is empty. Set it in the workflow's Configure Workflow screen." "$out"
assert_eq "empty command sends nothing" "no" "$(cmd_ran)"

reset_stubs
clip "Text"
saved_command=$SUM_COMMAND
unset SUM_COMMAND
HOME="$ZHOME" ZDOTDIR="$ZDIR" summarize clipboard
export SUM_COMMAND=$saved_command
# breaks-if: an unset SUM_COMMAND no longer falls back to the default command
assert_contains "unset command runs the default (claude through the stub)" "$out" "TL;DR: stub summary."
assert_eq "unset command reaches the backend" "yes" "$(cmd_ran)"

# ===================================================== the view protocol

reset_stubs
out=$(sum_job="" bash "$SCRIPT" "some typed text")
# breaks-if: an unknown argument starts a job
assert_eq "unknown source message" 'Pick the "Active window" or "Clipboard" row to summarize.' "$(printf '%s' "$out" | json_get '$d->{response}')"
assert_eq "unknown source asks for no rerun" "" "$(printf '%s' "$out" | json_get 'exists $d->{rerun} ? "rerun" : ""')"
assert_eq "unknown source starts no job" "0" "$(jobs_left)"

out=$(sum_job="$JOBS/job.gone" bash "$SCRIPT" clipboard)
# breaks-if: render keeps polling a job directory that no longer exists
assert_eq "missing job message" "This summary is gone. Run it again from the keyword." "$(printf '%s' "$out" | json_get '$d->{response}')"
assert_eq "missing job asks for no rerun" "" "$(printf '%s' "$out" | json_get 'exists $d->{rerun} ? "rerun" : ""')"

# A sum_job outside the jobs directory, or escaping it with "..", is never
# rendered, so a finished-looking directory there is never deleted.
mkdir -p "$STUBS/victim" "$JOBS/job.x"
: >"$STUBS/victim/done"
for bad in "$STUBS/victim" "$JOBS/job.x/../../../victim"; do
  out=$(sum_job="$bad" bash "$SCRIPT" clipboard)
  # breaks-if: view hands any sum_job to render, which deletes it once it has a done file
  assert_file "sum_job '$bad' is not deleted" "$STUBS/victim/done"
  assert_eq "sum_job '$bad' message" "This summary is gone. Run it again from the keyword." "$(printf '%s' "$out" | json_get '$d->{response}')"
  assert_eq "sum_job '$bad' is cleared" "" "$(printf '%s' "$out" | json_get '$d->{variables}{sum_job}')"
done
rm -rf "$STUBS/victim" "$JOBS/job.x"

# ===================================================== broken scripts still answer

# stage_scripts: a copy of scripts/ and prompt.md to break on purpose.
stage_scripts() {
  rm -rf "$STUBS/staged"
  mkdir -p "$STUBS/staged"
  cp -R "$ROOT/scripts" "$ROOT/prompt.md" "$STUBS/staged/"
}

reset_stubs
stage_scripts
sed -i '' 's/^  load_config$/  load_config; : "$UNDEFINED_FOR_THIS_TEST"/' "$STUBS/staged/scripts/summarize.sh"
window_app com.apple.Safari Safari
SCRIPT="$STUBS/staged/scripts/summarize.sh" summarize window
# breaks-if: finish stops writing a message for a job that died on its own
assert_contains "a crashed job still ends with a message" "$out" "Summarize stopped unexpectedly (exit code 1)."
assert_contains "the message carries the job's stderr" "$out" "UNDEFINED_FOR_THIS_TEST: unbound variable"
assert_eq "a crashed job leaves no directory" "0" "$(jobs_left)"

reset_stubs
stage_scripts
sed -i '' 's|^    /bin/bash "$LIB_DIR/summarize.sh" --run|    /nonexistent/bash "$LIB_DIR/summarize.sh" --run|' "$STUBS/staged/scripts/summarize.sh"
clip "Text"
SCRIPT="$STUBS/staged/scripts/summarize.sh" summarize clipboard
# breaks-if: render keeps rerunning a job whose launcher died before it started
assert_contains "a job that never started ends with a message" "$out" "Summarize stopped unexpectedly."
assert_contains "the message carries the launcher's error" "$out" "cannot run /nonexistent/bash"
# breaks-if: render hands a job whose launcher failed to the backend anyway
assert_eq "a job that never started sends nothing" "no" "$(cmd_ran)"
# breaks-if: render skips the rm -rf for a job whose launcher died before it started
assert_eq "a job that never started leaves no directory" "0" "$(jobs_left)"

reset_stubs
stage_scripts
sed -i '' 's/^  "\$PERL" -e /  sleep 1 \&\& exec "$PERL" -e /' "$STUBS/staged/scripts/summarize.sh"
clip "Text"
first=$(sum_job="" bash "$STUBS/staged/scripts/summarize.sh" clipboard 2>/dev/null)
# breaks-if: the first run takes a job whose launcher has not started yet for dead
assert_eq "a slow launcher still gets a rerun" "0.3" "$(printf '%s' "$first" | json_get '$d->{rerun}')"
job=$(printf '%s' "$first" | json_get '$d->{variables}{sum_job}')
for _ in $(seq 1 50); do [ -e "$job/done" ] && break; sleep 0.1; done
assert_file "the slow launcher's job still ran" "$job/done"
rm -rf "$job"

reset_stubs
stage_scripts
sed -i '' "s/'cut' => sub {/'cut' => sub { exit 2;/" "$STUBS/staged/scripts/text.pl"
clip "Text"
SCRIPT="$STUBS/staged/scripts/summarize.sh" summarize clipboard
# breaks-if: any non-zero exit of the cut is read as "input was cut"
assert_eq "a failing cut is an error, not a cut" "Could not prepare the input for the command." "$out"
assert_eq "a failing cut sends nothing" "no" "$(cmd_ran)"
SCRIPT="$STUBS/staged/scripts/summarize.sh" run_job_alone clipboard
# breaks-if: drop_content stops deleting input.cut, which a failed cut leaves behind
refute_content "failed cut"

reset_stubs
stage_scripts
rm "$STUBS/staged/prompt.md"
clip "Text"
SCRIPT="$STUBS/staged/scripts/summarize.sh" summarize clipboard
# breaks-if: a missing prompt.md sends an empty prompt to the command
assert_eq "missing prompt.md" "Could not read prompt.md." "$out"
assert_eq "missing prompt.md sends nothing" "no" "$(cmd_ran)"

# ===================================================== lib.sh: setup_env

home="$STUBS/home"
mkdir -p "$home/.local/bin" "$home/.volta/bin" "$STUBS/npm/bin"
# lib_env PREFIX: PATH and LANG after setup_env, as "PATH|LANG".
lib_env() {
  HOME="$home" NPM_CONFIG_PREFIX="$1" PATH=/usr/bin:/bin LANG=C /bin/bash -c \
    'source "$1/scripts/lib.sh"; setup_env; printf "%s|%s" "$PATH" "$LANG"' _ "$ROOT"
}
out=$(lib_env "")
assert_contains "setup_env prepends an existing dir, in list order" "$out" "$home/.local/bin:$home/.volta/bin:"
assert_contains "setup_env keeps the old PATH at the end" "$out" ":/usr/bin:/bin|"
# breaks-if: setup_env prepends directories that do not exist
refute_contains "setup_env skips a missing dir" "$out" "$home/.claude/local"
# breaks-if: setup_env adds "/bin" for an empty NPM_CONFIG_PREFIX
refute_contains "setup_env skips an empty NPM_CONFIG_PREFIX" "$out" ":/bin:/usr/bin"
assert_contains "setup_env exports a UTF-8 locale" "$out" "|en_US.UTF-8"
out=$(lib_env "$STUBS/npm")
assert_contains "setup_env adds NPM_CONFIG_PREFIX/bin when set" "$out" "$home/.volta/bin:$STUBS/npm/bin:"

# ===================================================== lib.sh: tool_run

# lib_tool VALUE ARGS...: runs tool_run SUM_X ARGS under set -u, with SUM_X set
# to VALUE.
lib_tool() {
  local value="$1"
  shift
  SUM_X="$value" /bin/bash -c 'set -u; source "$1/scripts/lib.sh"; shift; tool_run SUM_X "$@"' _ "$ROOT" "$@"
}
assert_eq "tool_run runs the tool in VAR" "hi-" "$(lib_tool 'printf %s-' echo 5 hi)"
# breaks-if: tool_run ignores DEFAULT when VAR is empty
assert_eq "tool_run falls back to DEFAULT for an empty VAR" "hi" "$(lib_tool "" echo 5 hi)"
# breaks-if: the empty-words guard in tool_run goes and set -u aborts on a blank VAR
assert_eq "tool_run falls back to DEFAULT for a blank VAR" "hi" "$(lib_tool " " echo 5 hi 2>&1)"
# breaks-if: tool_run stops running the tool under timeout.pl
lib_tool "" sleep 1 5 >/dev/null 2>&1
assert_eq "tool_run exits 124 when the tool runs too long" "124" "$?"

# ===================================================== info.plist wiring

PLIST="$ROOT/info.plist"
assert_eq "Text View runs summarize.sh" "scripts/summarize.sh" "$(plutil -extract objects.1.config.inputfile raw -o - "$PLIST")"
assert_eq "Text View takes a script as input" "1" "$(plutil -extract objects.1.config.inputtype raw -o - "$PLIST")"
sf=$(plutil -extract objects.0.uid raw -o - "$PLIST")
tv=$(plutil -extract objects.1.uid raw -o - "$PLIST")
assert_eq "Script Filter connects to the Text View" "$tv" "$(plutil -extract "connections.$sf.0.destinationuid" raw -o - "$PLIST")"
assert_eq "summarize.sh starts with a bash shebang" "#!/bin/bash" "$(head -n 1 "$SCRIPT")"

# shellcheck source=scripts/lib.sh
plist_cmd=$(plutil -extract userconfigurationconfig.1.config.default raw -o - "$PLIST")
lib_cmd=$(source "$ROOT/scripts/lib.sh" && printf '%s' "$DEFAULT_COMMAND")
assert_eq "plist default command matches the script's" "$lib_cmd" "$plist_cmd"
# breaks-if: --strict-mcp-config is dropped and the backend loads the user's MCP servers
assert_eq "default command" 'claude -p --model "$SUM_MODEL" --tools "" --strict-mcp-config --no-session-persistence --system-prompt "$SUM_PROMPT"' "$plist_cmd"
for pair in SUM_MAX_CHARS:200000 SUM_TIMEOUT:120 SUM_FETCH_TIMEOUT:15 SUM_APP_TIMEOUT:60; do
  assert_eq "advanced default ${pair%%:*}" "${pair#*:}" "$(plutil -extract "variables.${pair%%:*}" raw -o - "$PLIST")"
  assert_contains "script default ${pair%%:*}" "$(grep -F "${pair%%:*}=\"\${${pair%%:*}:-" "$SCRIPT")" ":-${pair#*:}}"
done
configured=$(plutil -convert json -o - "$PLIST" | json_get 'join ",", map { $_->{variable} } @{$d->{userconfigurationconfig}}')
assert_eq "Configure Workflow fields" "SUM_KEYWORD,SUM_COMMAND,SUM_MODEL,SUM_LANGUAGE,SUM_MIN_BULLETS,SUM_MAX_BULLETS,SUM_PROMPT_OVERRIDE" "$configured"
# The indices follow the field order the assertion above pins.
for entry in 2:SUM_MODEL:sonnet 4:SUM_MIN_BULLETS:3 5:SUM_MAX_BULLETS:10; do
  idx=${entry%%:*}
  pair=${entry#*:}
  var=${pair%%:*}
  # breaks-if: a Configure Workflow default in info.plist drifts from the fallback in summarize.sh
  assert_eq "plist default $var" "${pair#*:}" "$(plutil -extract "userconfigurationconfig.$idx.config.default" raw -o - "$PLIST")"
  assert_contains "script default $var" "$(grep -F "$var=\"\${$var:-" "$SCRIPT")" ":-${pair#*:}}"
done

finish_tests
