#!/bin/bash
# Unit tests for scripts/text.pl, scripts/timeout.pl and the HTML-to-text
# step of scripts/summarize.sh. The HTML cases run the real textutil on the
# pages in test/fixtures/; every resource those pages link to is on the
# reserved .invalid domain, so nothing reaches the network.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/test/fixtures"
# shellcheck source=test/helpers.sh
source "$ROOT/test/helpers.sh"

TP() { /usr/bin/perl "$ROOT/scripts/text.pl" "$@"; }
TO() { /usr/bin/perl "$ROOT/scripts/timeout.pl" "$@"; }
# UH STRING: url-host with STRING on stdin.
UH() { printf '%s' "$1" | TP url-host; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- trim ---
assert_eq "trim strips spaces, tabs and newlines on both ends" "a b" "$(printf ' \n\ta b \n\n' | TP trim)"
assert_eq "trim of only whitespace is empty" "" "$(printf ' \n\t ' | TP trim)"

# --- internal-ip: which addresses a fetch must refuse ---
II() { printf '%s' "$1" | TP internal-ip; }
for ip in 127.0.0.1 127.255.255.255 10.0.0.1 172.16.0.1 172.31.255.255 192.168.0.1 \
  169.254.169.254 100.64.0.1 0.0.0.0 198.18.0.1 224.0.0.1 ::1 :: fe80::1 fc00::1 fd12::1 \
  ff02::1 ::ffff:127.0.0.1 ::ffff:192.168.0.1 ::ffff:7f00:1 garbage ''; do
  # breaks-if: internal_ip stops treating this address as internal
  II "$ip"
  assert_eq "internal: '$ip'" "0" "$?"
done
for ip in 93.184.216.34 8.8.8.8 172.15.255.255 172.32.0.1 100.63.255.255 100.128.0.1 \
  192.169.0.1 198.20.0.1 2606:4700::1111 ::ffff:8.8.8.8; do
  # breaks-if: internal_ip refuses public addresses next to the private ranges
  II "$ip"
  assert_eq "public: $ip" "1" "$?"
done

# --- url-host: what counts as a URL ---
assert_eq "https URL" "example.com" "$(UH 'https://example.com/a?b=1')"
assert_eq "scheme in any case" "example.com" "$(UH 'HTTP://Example.COM/x')"
assert_eq "port and user info are not the host" "example.com" "$(UH 'https://user:pw@example.com:8443/x')"
assert_eq "no path at all" "example.com" "$(UH 'http://example.com')"
# breaks-if: url_host accepts a scheme with no host
UH 'http://' >/dev/null
assert_eq "lone http:// is text" "1" "$?"
# breaks-if: url_host accepts an empty host before the path
UH 'https:///path' >/dev/null
assert_eq "empty host is text" "1" "$?"
# breaks-if: url_host stops requiring a scheme
UH 'example.com/page' >/dev/null
assert_eq "bare domain is text" "1" "$?"
# breaks-if: url_host accepts schemes other than http and https
UH 'ftp://example.com/file' >/dev/null
assert_eq "ftp URL is text" "1" "$?"
# breaks-if: url_host stops rejecting whitespace inside the string
UH $'https://example.com\nmore text' >/dev/null
assert_eq "URL followed by more lines is text" "1" "$?"
# breaks-if: url_host stops requiring the whole string to be one URL token
UH 'see https://example.com' >/dev/null
assert_eq "text that contains a URL is text" "1" "$?"
# breaks-if: url-host treats empty stdin as a URL or dies on it
TP url-host </dev/null >/dev/null 2>&1
assert_eq "url-host with empty stdin is text" "1" "$?"
pad=$(printf 'a%.0s' $(seq 1 2028))
assert_eq "a 2048-character URL is a URL" "example.com" "$(UH "https://example.com/$pad")"
# breaks-if: url_host drops its length limit, so the job fetches what the Script Filter calls text
UH "https://example.com/${pad}a" >/dev/null
assert_eq "a 2049-character URL is text" "1" "$?"
# breaks-if: url_host counts bytes instead of characters
assert_eq "the length limit counts characters" "example.com" "$(UH "https://example.com/${pad//a/é}")"

# --- preview: the 60-character boundary, counted in characters ---
s60=$(printf 'a%.0s' $(seq 1 60))
assert_eq "exactly 60 characters stay whole" "$s60" "$(printf '%s' "$s60" | TP preview 60)"
assert_eq "61 characters are cut to 60 plus an ellipsis" "${s60}…" "$(printf '%sb' "$s60" | TP preview 60)"
u60=$(printf 'ü%.0s' $(seq 1 60))
assert_eq "multi-byte characters count as one" "$u60" "$(printf '%s' "$u60" | TP preview 60)"
assert_eq "newlines and runs of spaces become one space" "a b c" "$(printf ' a\n\n  b\tc ' | TP preview 60)"
# breaks-if: preview accepts a zero or missing length
out=$(printf 'abc' | TP preview 0 2>&1)
assert_eq "preview 0 exit code" "255" "$?"
assert_contains "preview 0 message" "$out" "N must be a whole number of 1 or more"
# breaks-if: positive_int drops the defined check
out=$(printf 'abc' | TP preview 2>&1)
assert_eq "preview with no N exit code" "255" "$?"
assert_contains "preview with no N message" "$out" "N must be a whole number of 1 or more"
for bad in -1 1.5 ''; do
  # breaks-if: positive_int loosens its whole-number check
  printf 'abc' | TP preview "$bad" >/dev/null 2>&1
  assert_eq "preview \"$bad\" is refused" "255" "$?"
done

# --- cut: exit 10 only when it cut ---
printf 'abcde' | TP cut 5 >"$WORK/cut"
assert_eq "cut at exactly the length exits 0" "0" "$?"
assert_eq "cut at exactly the length keeps all" "abcde" "$(cat "$WORK/cut")"
# breaks-if: cut stops reporting that it cut something
printf 'abcdef' | TP cut 5 >"$WORK/cut"
assert_eq "one character over exits 10" "10" "$?"
assert_eq "one character over is cut to the limit" "abcde" "$(cat "$WORK/cut")"
printf 'äöüßé' | TP cut 3 >"$WORK/cut"
assert_eq "cut never splits a multi-byte character" "äöü" "$(cat "$WORK/cut")"
printf '' | TP cut 1 >"$WORK/cut"
assert_eq "empty input exits 0" "0" "$?"
# breaks-if: cut accepts a non-numeric length
printf 'abc' | TP cut x >/dev/null 2>&1
assert_eq "non-numeric length is refused" "255" "$?"

# --- count ---
assert_eq "count counts characters, not bytes" "3" "$(printf 'äöü' | TP count)"
assert_eq "count of nothing is 0" "0" "$(printf '' | TP count)"

# --- malformed UTF-8 becomes U+FFFD instead of an error ---
# breaks-if: utf8_in decodes with a strict check and dies on bad bytes
out=$(printf 'a\xe2\x80' | TP trim)
assert_eq "trim of a cut-off character exits 0" "0" "$?"
assert_contains "trim keeps the text before a cut-off character" "$out" "a"
assert_contains "trim turns a cut-off character into U+FFFD" "$out" "�"
printf 'a\xe2\x80' | TP cut 100 >/dev/null
assert_eq "cut of a cut-off character exits 0" "0" "$?"
mkdir -p "$WORK/partial-job"
printf 'TL;DR: half\xe2\x80' >"$WORK/partial-job/out"
out=$(TP view-running "$WORK/partial-job")
assert_eq "view-running with a cut-off character exits 0" "0" "$?"
assert_contains "view-running still shows the output so far" "$out" "TL;DR: half"

# --- view-running and view-final: no remote resources in the output ---
# view MODE TEXT: the Text View response for a job whose output is TEXT.
mkdir -p "$WORK/view-job"
view() {
  printf '%s' "$2" >"$WORK/view-job/out"
  # shellcheck disable=SC2016 # Perl code, not shell
  TP "$1" "$WORK/view-job" | json_get '$d->{response}'
}
plain=$'TL;DR: Sales rose 4% [see table] (Q3).\n\n- a < b and c > d.\n- Use `x` and *y*, 3! [1]'
assert_eq "view-final leaves a plain summary unchanged" "$plain" "$(view view-final "$plain")"
assert_eq "view-running leaves a plain summary unchanged" "$plain" "$(view view-running "$plain")"
# breaks-if: view-final shows the command's output without no_remote
assert_eq "image becomes a label" "a [image: x] b" "$(view view-final 'a ![x](http://127.0.0.1:8000/probe?d=secret) b')"
# breaks-if: view-running shows the command's output without no_remote
assert_eq "image becomes a label while running" "[image: x]" "$(view view-running '![x](http://127.0.0.1:8000/probe)')"
# breaks-if: no_remote stops stripping HTML tags
assert_eq "HTML tags are stripped" "x  y bold" "$(view view-final 'x <img src="https://e.invalid/p.png"> y <b>bold</b>')"
# breaks-if: neither the tag rule nor the outer loop repeats, so removing an inner tag rebuilds an outer one
assert_eq "a tag rebuilt by removing an inner tag is stripped" "a  b" "$(view view-final 'a <<b>img src="https://e.invalid/p"> b')"
# breaks-if: the passes run once, so a link rewrite that joins a tag leaves it in place
assert_eq "a tag rebuilt by a link rewrite is stripped" "a  b" "$(view view-final 'a <[img](u) src="https://e.invalid/p"> b')"
# breaks-if: the HTML comment rule is removed
assert_eq "HTML comments are stripped" "a  b" "$(view view-final 'a <!-- <img src=x> --> b')"
# breaks-if: the autolink rule is removed and the tag rule deletes the whole address
assert_eq "autolink keeps its URL as text" "see https://e.invalid/x" "$(view view-final 'see <https://e.invalid/x>')"
assert_eq "mailto autolink keeps its address as text" "mail mailto:a@e.invalid" "$(view view-final 'mail <mailto:a@e.invalid>')"
# breaks-if: links keep their destination and stay live
assert_eq "link keeps only its text" "See docs now." "$(view view-final 'See [docs](https://e.invalid/a_(b)) now.')"
# breaks-if: $BRACKETS stops crossing a single line break and a two-line link stays live
assert_eq "link text across two lines" $'See do\ncs now.' "$(view view-final $'See [do\ncs](https://e.invalid) now.')"
# breaks-if: $BRACKETS ignores backslash escapes and a link with \] in its text stays live
assert_eq "link text with an escaped bracket" 'See a\]b now.' "$(view view-final 'See [a\]b](https://e.invalid) now.')"
# breaks-if: reference definitions keep their [label]: syntax and a reference link becomes live
assert_eq "reference definition loses its syntax" $'See [docs][1].\n\n1: https://e.invalid/p.png' \
  "$(view view-final $'See [docs][1].\n\n[1]: https://e.invalid/p.png')"
assert_eq "indented definition in a quote loses its syntax" '>     r: https://e.invalid/p' "$(view view-final '>     [r]: https://e.invalid/p')"
assert_eq "shortcut image becomes a label" $'[image: r]\n\nr: https://e.invalid/p.png' \
  "$(view view-final $'![r]\n\n[r]: https://e.invalid/p.png')"
# breaks-if: the link pass stops matching nested brackets
assert_eq "image inside a link" "[image: badge]" "$(view view-final '[![badge](https://e.invalid/b.svg)](https://e.invalid)')"
# breaks-if: the image pass runs only once
assert_eq "image inside an image" "[image: outer [image: inner] text]" "$(view view-final '![outer ![inner](u2) text](u1)')"
# breaks-if: the link rule matches a label followed by brackets again, as a reference link
assert_eq "two images side by side" "[image: a][image: b]" "$(view view-final '![a](u)![b](v)')"
# breaks-if: $BRACKETS stops crossing a single line break and a two-line image keeps its URL
assert_eq "image alt text across two lines" $'[image: a\nb]' "$(view view-final $'![a\nb](https://e.invalid/p)')"
# breaks-if: $LINE lets brackets cross a blank line, which Markdown never does
assert_eq "a blank line ends the alt text" $'![a\n\nb]' "$(view view-final $'![a\n\nb]')"
# breaks-if: an image cut off at a chunk boundary is shown with its URL until it completes
assert_eq "unterminated image while streaming" "s [image: alt]" "$(view view-running 's ![alt](https://e.invalid/?d=sec')"
# breaks-if: the tail rule for an image cut inside its alt text is removed
assert_eq "image cut inside its alt text" "s [image: al]" "$(view view-running 's ![al')"
assert_eq "image cut inside two-line alt text" $'s [image: al\nt]' "$(view view-running $'s ![al\nt')"
# breaks-if: the image rule requires a destination after the alt text
assert_eq "image cut between alt and URL" "s [image: alt]" "$(view view-running 's ![alt]')"
# breaks-if: $DEST requires its closing parenthesis and a cut-off link shows its URL
assert_eq "unterminated link while streaming" "s docs" "$(view view-running 's [docs](https://e.invalid/?d=sec')"
# breaks-if: an HTML tag cut off at a chunk boundary is shown until its > arrives
assert_eq "unterminated HTML tag while streaming" "s" "$(view view-running 's <img src="https://e.invalid/p')"
# breaks-if: the comment rule needs its --> and a cut-off comment shows its tag
assert_eq "unterminated HTML comment while streaming" "s" "$(view view-running 's <!-- <img src=x')"
rm -f "$WORK/view-job/out"
printf 'The command failed with exit code 1.\n<img src="https://e.invalid/p"> ![e](https://e.invalid/q)\n' >"$WORK/view-job/msg"
# breaks-if: the command's stderr in msg skips no_remote
# shellcheck disable=SC2016 # Perl code, not shell
assert_eq "stderr in the failure message is cleaned too" $'The command failed with exit code 1.\n [image: e]' \
  "$(TP view-final "$WORK/view-job" | json_get '$d->{response}')"

# --- clean-text ---
assert_eq "line separators become newlines, blank runs squeeze to one" \
  $'a\nb\n\nc' "$(printf 'a\xe2\x80\xa8b\n\n\n\n  \nc  \n' | TP clean-text)"
# breaks-if: clean-text stops turning CRLF and lone CR line ends into newlines
assert_eq "CRLF and lone CR become newlines" $'a\nb\nc' "$(printf 'a\r\nb\rc\r\n' | TP clean-text)"

# --- fill-prompt ---
out=$(printf 'Use {min_bullets} to {max_bullets} bullets in {language}. {min_bullets}' | TP fill-prompt 2 7 German)
assert_eq "every placeholder filled" "Use 2 to 7 bullets in German. 2" "$out"
out=$(printf 'Write in {language}.' | TP fill-prompt 3 10 '')
assert_eq "empty language means the input's language" "Write in the same language as the input." "$out"
out=$(printf 'Write in {language}.' | TP fill-prompt 3 10 '  ')
assert_eq "blank language means the input's language" "Write in the same language as the input." "$out"
# breaks-if: fill-prompt interpolates the language value or fills placeholders inside it
# shellcheck disable=SC2016 # the $ is literal on purpose
lang='$HOME \1 {min_bullets}'
out=$(printf 'Use {min_bullets} in {language}.' | TP fill-prompt 3 10 "$lang")
assert_eq "language with \$, \\ and a placeholder stays literal" "Use 3 in $lang." "$out"

# --- unknown command ---
# breaks-if: text.pl silently ignores an unknown command
out=$(TP nope 2>&1)
assert_eq "unknown command exit code" "255" "$?"
assert_contains "unknown command message" "$out" "usage: text.pl"

# --- html_to_text on fixtures ---
# html_to_text reads SUM_TEXTUTIL and SUM_FETCH_TIMEOUT. Drop whatever the
# caller's shell exports, as test/stubs.sh does for the flow tests.
reset_test_env
# shellcheck source=scripts/summarize.sh
source "$ROOT/scripts/summarize.sh"

start=$SECONDS
text=$(html_to_text <"$FIXTURES/article.html")
assert_eq "linked remote resources don't stall textutil" "1" "$(( SECONDS - start < 10 ))"
assert_contains "article heading kept" "$text" "Tide pools after the storm"
assert_contains "article body kept with entities decoded" "$text" "Fish & crabs returned within days."
assert_contains "second paragraph kept" "$text" "second count in March"
for junk in TRACKER_SCRIPT_TEXT NAV_LINK_HOME FOOTER_COPYRIGHT_TEXT COMMENT_TEXT ASIDE_PROMO_TEXT \
    NOSCRIPT_TEXT IMAGE_ALT_TEXT SITE_TOPBAR_LINKS font-family; do
  # breaks-if: strip-html stops removing that element (or the single-<main> rule goes)
  refute_contains "article drops $junk" "$text" "$junk"
done

text=$(html_to_text <"$FIXTURES/table.html")
assert_contains "table header row" "$text" "Route"
assert_contains "table cell" "$text" "Harbor to Island"
assert_contains "table cell in another row" "$text" "4 EUR"
assert_contains "text after the table" "$text" "Bikes travel for free"

text=$(html_to_text <"$FIXTURES/script-heavy.html")
assert_contains "the one real sentence survives" "$text" "release ships on Tuesday"
for junk in SCRIPT_CONFIG_TEXT LDJSON_TEXT STYLE_TEXT SVG_TEXT TEMPLATE_TEXT IFRAME_TEXT BUTTON_TEXT \
    OPTION_TEXT UPPERCASE_SCRIPT_TEXT MULTILINE_SCRIPT_TEXT BODY_STYLE_TEXT BODY_LDJSON_TEXT \
    LOOSE_BUTTON_TEXT LOOSE_OPTION_TEXT; do
  # breaks-if: strip-html stops removing that element, or matches tag names case-sensitively
  refute_contains "script-heavy page drops $junk" "$text" "$junk"
done

text=$(html_to_text <"$FIXTURES/two-mains.html")
# breaks-if: the <main> rule applies when a page has more than one <main>
assert_contains "two <main> elements: outside text kept" "$text" "OUTSIDE_TEXT"
assert_contains "two <main> elements: first kept" "$text" "FIRST_MAIN_TEXT"
assert_contains "two <main> elements: second kept" "$text" "SECOND_MAIN_TEXT"

text=$(html_to_text iso-8859-1 <"$FIXTURES/latin1.html")
assert_contains "charset from the header decodes Latin-1" "$text" "Café crème in Latin-1."

text=$(html_to_text <"$FIXTURES/meta-utf8.html")
assert_contains "<meta charset> decodes UTF-8" "$text" "Grüße aus Köln."
# breaks-if: a <meta> charset is ignored and the UTF-8 bytes are decoded as Latin-1
refute_contains "<meta charset> page is not read as Latin-1" "$text" "GrÃ¼"
# breaks-if: strip-html removes <meta> before reading the charset from it, or misses the http-equiv form
text=$(html_to_text <"$FIXTURES/meta-latin1.html")
assert_contains "<meta http-equiv> charset decodes Latin-1" "$text" "Café crème in Latin-1."
# breaks-if: the page's <meta> wins over the charset from the HTTP header
text=$(html_to_text iso-8859-1 <"$FIXTURES/meta-utf8.html")
assert_contains "header charset wins over <meta>" "$text" "GrÃ¼"
# breaks-if: an unknown header charset is used as is or fails the page instead of falling back to <meta>
text=$(html_to_text x-no-such-charset <"$FIXTURES/meta-latin1.html")
assert_eq "unknown header charset exit code" "0" "$?"
assert_contains "unknown header charset falls back to <meta>" "$text" "Café crème in Latin-1."
# breaks-if: a page with no charset anywhere is left to textutil's guess instead of UTF-8
text=$(printf '<html><body><p>Grüße aus Köln.</p></body></html>' | html_to_text)
assert_contains "no charset anywhere decodes UTF-8" "$text" "Grüße aus Köln."
# breaks-if: an unknown <meta> charset fails the page instead of falling back to UTF-8
text=$(printf '<html><head><meta charset="x-no-such-charset"></head><body><p>Grüße.</p></body></html>' | html_to_text)
assert_contains "unknown <meta> charset falls back to UTF-8" "$text" "Grüße."
# breaks-if: meta_charsets stops at the first <meta>, or requires lower-case tags
text=$(printf '<html><head><meta name="viewport" content="width=device-width"><META CHARSET=iso-8859-1></head><body><p>Caf\xe9.</p></body></html>' | html_to_text)
assert_contains "charset in a later, upper-case, unquoted <meta> is read" "$text" "Café."
# breaks-if: meta_charsets requires double quotes around the charset value
text=$(printf "<html><head><meta charset='iso-8859-1'></head><body><p>Caf\xe9.</p></body></html>" | html_to_text)
assert_contains "single-quoted <meta> charset is read" "$text" "Café."
# breaks-if: meta_charsets returns only the first name, so an unknown one hides a later valid one
text=$(printf '<html><head><meta charset="x-no-such-charset"><meta charset="iso-8859-1"></head><body><p>Caf\xe9.</p></body></html>' | html_to_text)
assert_contains "unknown <meta> charset falls through to the next <meta>" "$text" "Café."
# breaks-if: a <meta> naming UTF-16, UTF-32 or UCS-2 is used as is and turns the page into garbage
for wide in utf-16 UTF-32 ucs-2; do
  text=$(printf '<html><head><meta charset="%s"></head><body><p>Grüße.</p></body></html>' "$wide" | html_to_text)
  assert_contains "<meta charset=$wide> means UTF-8" "$text" "Grüße."
done
# breaks-if: a <meta> naming UTF-7 or a MIME codec is used to decode the page
for odd in utf-7 MIME-Header; do
  text=$(printf '<html><head><meta charset="%s"></head><body><p>Gr+APw-e =?UTF-8?Q?Gr=C3=BC?=.</p></body></html>' "$odd" | html_to_text)
  assert_contains "<meta charset=$odd> is skipped" "$text" "Gr+APw-e =?UTF-8?Q?Gr=C3=BC?=."
done
# breaks-if: meta_charsets runs before comments are removed
text=$(printf '<html><head><!-- <meta charset="iso-8859-1"> --></head><body><p>Grüße.</p></body></html>' | html_to_text)
assert_contains "<meta> inside a comment is ignored" "$text" "Grüße."
# breaks-if: strip-html prints the input bytes or the charset it decoded with instead of UTF-8
assert_eq "strip-html output is UTF-8 whatever the input charset" "<p>Café</p>" \
  "$(printf '<p>Caf\xe9</p>' | TP strip-html iso-8859-1)"
# breaks-if: strip-html decodes with a strict check and dies on bad bytes
out=$(printf '<p>a\xe2\x80</p>' | TP strip-html)
assert_eq "strip-html of a cut-off UTF-8 character exits 0" "0" "$?"
assert_contains "strip-html keeps the text around a cut-off character" "$out" "<p>a"
assert_contains "strip-html turns a cut-off character into U+FFFD" "$out" "�"

text=$(html_to_text <"$FIXTURES/form-page.html")
# breaks-if: strip-html removes <form> with everything inside it
assert_contains "page inside one <form> keeps its heading" "$text" "Opening hours"
assert_contains "page inside one <form> keeps its text" "$text" "FORM_BODY_TEXT"
for junk in VIEWSTATE_VALUE INPUT_VALUE TEXTAREA_TEXT OPTION_TEXT BUTTON_TEXT; do
  # breaks-if: strip-html stops removing that form control
  refute_contains "page inside one <form> drops $junk" "$text" "$junk"
done

# --- decode ---
assert_eq "decode with a charset" "Café" "$(printf 'Caf\xe9' | TP decode iso-8859-1)"
assert_eq "decode without a charset reads UTF-8" "Café" "$(printf 'Caf\xc3\xa9' | TP decode)"
# breaks-if: decode dies on a charset name Encode does not know
assert_eq "decode with an unknown charset reads UTF-8" "Café" "$(printf 'Caf\xc3\xa9' | TP decode x-no-such-charset)"
# breaks-if: iso-8859-1 is decoded as strict Latin-1 and 0x92 becomes a control character
assert_eq "decode treats iso-8859-1 as windows-1252" "it’s" "$(printf 'it\x92s' | TP decode iso-8859-1)"
# breaks-if: a UTF-7 or MIME charset from the header is used to decode the text
for odd in utf-7 MIME-Header; do
  assert_eq "decode skips the $odd charset" "Gr+APw-e" "$(printf 'Gr+APw-e' | TP decode "$odd")"
done
# breaks-if: decode decodes with a strict check and dies on bad bytes
out=$(printf 'a\xe2\x80' | TP decode)
assert_eq "decode of a cut-off UTF-8 character exits 0" "0" "$?"
assert_contains "decode turns a cut-off character into U+FFFD" "$out" "a�"

# --- timeout.pl ---
TO 5 /bin/bash -c 'exit 3'
assert_eq "command's own exit code passes through" "3" "$?"
assert_eq "command's stdout passes through" "hi" "$(TO 5 /bin/echo hi)"

start=$SECONDS
# breaks-if: timeout.pl stops killing the command when the alarm fires
TO 1 /bin/bash -c "sleep 30 & echo \$! >'$WORK/grandchild'; wait"
assert_eq "hanging command exits 124" "124" "$?"
assert_eq "hanging command stops near the limit" "1" "$(( SECONDS - start < 6 ))"
sleep 0.2
# breaks-if: the kill goes to the child only, not its process group
assert_file "grandchild pid was recorded" "$WORK/grandchild"
gc=$(cat "$WORK/grandchild" 2>/dev/null)
if [ -z "$gc" ]; then
  not_ok "grandchild pid file is empty"
elif kill -0 "$gc" 2>/dev/null; then
  not_ok "a process started by the timed-out command should be killed too"
else
  ok
fi

/usr/bin/perl "$ROOT/scripts/timeout.pl" 30 /bin/bash -c "sleep 30 & echo \$! >'$WORK/term-grandchild'; wait" &
pid=$!
for _ in $(seq 1 20); do [ -s "$WORK/term-grandchild" ] && break; sleep 0.1; done
kill -TERM "$pid"
wait "$pid"
# breaks-if: timeout.pl stops passing a TERM on to the command's group
assert_eq "TERM to timeout.pl exits 143" "143" "$?"
sleep 0.2
assert_file "TERM grandchild pid was recorded" "$WORK/term-grandchild"
gc=$(cat "$WORK/term-grandchild" 2>/dev/null)
if [ -z "$gc" ]; then
  not_ok "TERM grandchild pid file is empty"
elif kill -0 "$gc" 2>/dev/null; then
  not_ok "TERM to timeout.pl should stop the command's whole group"
else
  ok
fi

# A TERM that arrives before timeout.pl has its handlers must still stop
# the command. The window between fork and the handlers is too short to hit
# on purpose, so the TERM is sent before timeout.pl even starts: blocked and
# pending, it survives the exec and arrives once timeout.pl unblocks it.
# The command inherits the blocked TERM, so the KILL after the grace period
# is what ends it. Without the handler, Perl dies on the TERM and the
# command outlives it.
# The marker is the sleep's duration: long, so the command cannot end on its
# own during the check, unique per run, and free of regex characters for pgrep.
marker="$((100000 + $$))"
# shellcheck disable=SC2016 # Perl code, not shell
/usr/bin/perl -MPOSIX -e '
  POSIX::sigprocmask(POSIX::SIG_BLOCK(), POSIX::SigSet->new(POSIX::SIGTERM()));
  kill "TERM", $$;
  exec @ARGV' /usr/bin/perl "$ROOT/scripts/timeout.pl" 30 /bin/sleep "$marker"
# breaks-if: timeout.pl never unblocks TERM, or installs its handlers only after a TERM can arrive
assert_eq "an early TERM to timeout.pl exits 143" "143" "$?"
if pgrep -f "sleep $marker" >/dev/null; then
  not_ok "an early TERM to timeout.pl should stop the command"
  pkill -KILL -f "sleep $marker"
else
  ok
fi

# breaks-if: timeout.pl hands the command the TERM it blocked for itself
# shellcheck disable=SC2016 # Perl code, not shell
mask=$(TO 5 /usr/bin/perl -MPOSIX -e '
  my $m = POSIX::SigSet->new;
  POSIX::sigprocmask(POSIX::SIG_BLOCK(), POSIX::SigSet->new, $m);
  print $m->ismember(POSIX::SIGTERM()) ? "blocked" : "open"')
assert_eq "the command starts with TERM not blocked" "open" "$mask"

start=$SECONDS
TO 1 /bin/bash -c "trap '' TERM; sleep 30 & echo \$! >'$WORK/ignores-term'; wait"
assert_eq "command that ignores TERM exits 124" "124" "$?"
# breaks-if: the KILL escalation in the ALRM handler is removed
assert_eq "command that ignores TERM is killed after the grace period" "1" "$(( SECONDS - start < 8 ))"
sleep 0.2
gc=$(cat "$WORK/ignores-term" 2>/dev/null)
if [ -z "$gc" ]; then
  not_ok "the TERM-ignoring command never recorded its pid"
elif kill -0 "$gc" 2>/dev/null; then
  not_ok "a command that ignores TERM should be killed"
  kill -KILL "$gc" 2>/dev/null
else
  ok
fi

/usr/bin/perl "$ROOT/scripts/timeout.pl" 1 /bin/bash -c "(trap '' TERM; exec sleep 30) & echo \$! >'$WORK/stubborn'; wait"
assert_eq "command that dies on TERM exits 124" "124" "$?"
sleep 0.2
assert_file "stubborn grandchild pid was recorded" "$WORK/stubborn"
gc=$(cat "$WORK/stubborn" 2>/dev/null)
# breaks-if: timeout.pl stops sending a last KILL to the group after reaping the command
if [ -z "$gc" ]; then
  not_ok "stubborn grandchild pid file is empty"
elif kill -0 "$gc" 2>/dev/null; then
  not_ok "a grandchild that ignores TERM should be killed once the command is gone"
  kill -KILL "$gc" 2>/dev/null
else
  ok
fi

# breaks-if: timeout.pl accepts a zero timeout
out=$(TO 0 /bin/echo hi 2>&1)
assert_eq "zero seconds exit code" "125" "$?"
assert_contains "zero seconds message" "$out" "usage: timeout.pl"
# breaks-if: timeout.pl accepts a non-numeric or negative timeout
out=$(TO abc /bin/echo hi 2>&1)
assert_eq "non-numeric seconds exit code" "125" "$?"
out=$(TO -1 /bin/echo hi 2>&1)
assert_eq "negative seconds exit code" "125" "$?"
# breaks-if: timeout.pl drops its upper bound and a huge value switches the timeout off
out=$(TO 100000001 /bin/echo hi 2>&1)
assert_eq "seconds above the cap exit code" "125" "$?"
assert_contains "seconds above the cap message" "$out" "usage: timeout.pl"
out=$(TO 4294967296 /bin/echo hi 2>&1)
assert_eq "seconds that wrap 32 bits exit code" "125" "$?"
assert_eq "seconds at the cap are accepted" "hi" "$(TO 100000000 /bin/echo hi)"
for bad in 1.5 '' $'1\n'; do
  # breaks-if: the SECONDS check stops anchoring on \A[0-9]+\z (a trailing newline slips through ^\d+$)
  out=$(TO "$bad" /bin/echo hi 2>&1)
  assert_eq "seconds \"$bad\" exit code" "125" "$?"
  assert_contains "seconds \"$bad\" message" "$out" "usage: timeout.pl"
done
# breaks-if: a command killed by a signal is reported with its raw status instead of 128 + signal
# shellcheck disable=SC2016 # $$ belongs to the inner bash
TO 5 /bin/bash -c 'kill -9 $$'
assert_eq "command killed by a signal exits 128 + signal" "137" "$?"
# breaks-if: timeout.pl accepts a missing command
out=$(TO 5 2>&1)
assert_eq "no command exit code" "125" "$?"
# breaks-if: an unstartable command is reported as success or as a timeout
out=$(TO 5 "$WORK/does-not-exist" 2>&1)
assert_eq "missing command exit code" "127" "$?"
assert_contains "missing command message" "$out" "cannot run"

finish_tests
