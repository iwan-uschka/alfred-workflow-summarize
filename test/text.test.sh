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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- trim ---
assert_eq "trim strips spaces, tabs and newlines on both ends" "a b" "$(printf ' \n\ta b \n\n' | TP trim)"
assert_eq "trim of only whitespace is empty" "" "$(printf ' \n\t ' | TP trim)"

# --- url-host: what counts as a URL ---
assert_eq "https URL" "example.com" "$(TP url-host 'https://example.com/a?b=1')"
assert_eq "scheme in any case" "example.com" "$(TP url-host 'HTTP://Example.COM/x')"
assert_eq "port and user info are not the host" "example.com" "$(TP url-host 'https://user:pw@example.com:8443/x')"
assert_eq "no path at all" "example.com" "$(TP url-host 'http://example.com')"
# breaks-if: url_host accepts a scheme with no host
TP url-host 'http://' >/dev/null
assert_eq "lone http:// is text" "1" "$?"
# breaks-if: url_host accepts an empty host before the path
TP url-host 'https:///path' >/dev/null
assert_eq "empty host is text" "1" "$?"
# breaks-if: url_host stops requiring a scheme
TP url-host 'example.com/page' >/dev/null
assert_eq "bare domain is text" "1" "$?"
# breaks-if: url_host accepts schemes other than http and https
TP url-host 'ftp://example.com/file' >/dev/null
assert_eq "ftp URL is text" "1" "$?"
# breaks-if: url_host stops rejecting whitespace inside the string
TP url-host $'https://example.com\nmore text' >/dev/null
assert_eq "URL followed by more lines is text" "1" "$?"
# breaks-if: url_host stops requiring the whole string to be one URL token
TP url-host 'see https://example.com' >/dev/null
assert_eq "text that contains a URL is text" "1" "$?"
# breaks-if: url-host treats a missing argument as a URL or dies on it
TP url-host >/dev/null 2>&1
assert_eq "url-host with no argument is text" "1" "$?"

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

# --- clean-text ---
assert_eq "line separators become newlines, blank runs squeeze to one" \
  $'a\nb\n\nc' "$(printf 'a\xe2\x80\xa8b\n\n\n\n  \nc  \n' | TP clean-text)"

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
