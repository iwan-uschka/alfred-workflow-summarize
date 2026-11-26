#!/bin/bash
# Text View script. Alfred runs it with the chosen row's argument, `window`
# or `clipboard`, and shows the JSON it prints.
#
#   summarize.sh window|clipboard     start a job and show its first state
#   summarize.sh --run JOB_DIR        the job itself (started by the line above)
#
# Alfred 5.5 streams into a Text View by rerunning its script: each run
# prints the text so far plus a `rerun` interval, and a `sum_job` variable
# that Alfred hands back on the next run. So the first run stops any older
# job, which can take up to 5 s, then starts the real work as a detached
# background job and returns without waiting for it. Every rerun only
# renders the job's files. The last render drops `rerun`, which stops the
# loop, and deletes the job directory.
#
# A job directory holds:
#   source       window or clipboard
#   pid          the job's process id, which is also its process group id
#   status       one line for the view while there is no output yet, which
#                can name the fetched host
#   clip         the clipboard as pbpaste printed it
#   pbpaste.err  pbpaste's stderr
#   page         the downloaded page, when the clipboard holds a URL
#   curl.err     curl's stderr
#   osa.err      osascript's stderr
#   input        the text sent to the command
#   input.cut    input cut to SUM_MAX_CHARS, renamed to input right away
#   notice       a note shown above the summary (input was cut)
#   out          the command's stdout, growing while it runs
#   err          the command's stderr
#   backend.pgid the command's process group while it runs (timeout.pl
#                writes it and removes it once the command has ended)
#   job.err     the job's own stderr, shown only if the job dies unexpectedly
#   msg          the failure message, if any
#   done         exists once the job has finished
#
# drop_content deletes clip, pbpaste.err, page, curl.err, osa.err, input
# and input.cut once the command has its input open. finish deletes them
# again, plus err and status, when the job ends. So a job that ends after
# its Text View was closed leaves no read text, only source, pid, notice,
# out, msg, job.err and done, until the next start. A job killed before
# finish runs keeps what it had at that moment, err and backend.pgid
# included, until an open view renders the failure or, with the view closed,
# until the next start.
#
# Must stay compatible with /bin/bash 3.2 (what Alfred runs).
set -uo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HINT_ACTIVE_WINDOW='Open the page in your browser and use the "Active window" row.'
# shellcheck disable=SC2016 # the backticks are literal text
HINT_LOGIN='Run `claude` once in a terminal to log in, or update `claude` if it rejected an option.'
# Fetched pages with less text than this are login walls, cookie banners or
# pages built by JavaScript, so summarizing them would mislead.
MIN_PAGE_CHARS=200
# Largest page download in bytes. text.pl reads the whole page into memory,
# so a bigger file fails as a curl error instead.
MAX_PAGE_BYTES=20000000
USER_AGENT='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'

jobs_dir() {
  printf '%s/jobs\n' "${alfred_workflow_cache:-${TMPDIR:-/tmp}/alfred-summarize}"
}

# ---------------------------------------------------------------- the view

# job_running DIR PID: true when PID still runs the job in DIR. A job that
# was killed or outlived a reboot leaves a stale pid behind, which may now
# belong to another process.
job_running() {
  [ -n "$2" ] || return 1
  case "$(ps -ww -o command= -p "$2" 2>/dev/null)" in
    *"summarize.sh --run $1") return 0 ;;
  esac
  return 1
}

# Stops every job still around, for example one whose Text View was closed
# while the backend was still running, and removes its directory. The job's
# EXIT trap still writes into the directory after the TERM, so the directory
# goes only once the job has ended. A job that is still running after
# STOP_WAIT_TENTHS tenths of a second gets a KILL, which no trap outlives.
# That KILL reaches the job and timeout.pl but not the backend, which runs
# in a group of its own. timeout.pl records that group in backend.pgid while
# the backend runs, and kill_backend signals it. The wait still stays well
# above timeout.pl's GRACE, so the backend normally ends first.
STOP_WAIT_TENTHS=50

# Kills the backend's process group recorded in DIR/backend.pgid. It does
# nothing without a numeric record, or when no process is left in the group.
# A backend that ended normally leaves no record, because timeout.pl removes
# it. A record left by a job killed from outside can name a group id that
# has since been reused: pgrep only shows that some process is in the group,
# not that it is the old backend.
kill_backend() {
  local pgid
  pgid=$(cat "$1/backend.pgid" 2>/dev/null)
  case "$pgid" in
    '' | *[!0-9]* | 0 | 1) return 0 ;;
  esac
  pgrep -g "$pgid" >/dev/null 2>&1 || return 0
  kill -KILL -- "-$pgid" 2>/dev/null
  return 0
}

stop_old_jobs() {
  local dir pid i
  for dir in "$1"/job.*; do
    [ -d "$dir" ] || continue
    pid=$(cat "$dir/pid" 2>/dev/null)
    if [ ! -e "$dir/done" ]; then
      if job_running "$dir" "$pid"; then
        kill -TERM -- "-$pid" 2>/dev/null
        for ((i = 0; i < STOP_WAIT_TENTHS; i++)); do
          job_running "$dir" "$pid" || break
          sleep 0.1
        done
        job_running "$dir" "$pid" && kill -KILL -- "-$pid" 2>/dev/null
      fi
      # Also for a job that is no longer running: a KILL from outside took
      # its timeout.pl down too, so the backend may still run.
      kill_backend "$dir"
    fi
    rm -rf "$dir"
  done
}

start_job() {
  local source="$1" root job
  case "$source" in
    window | clipboard) ;;
    *)
      text_pl view-message 'Pick the "Active window" or "Clipboard" row to summarize.'
      return
      ;;
  esac
  root=$(jobs_dir)
  mkdir -p "$root"
  stop_old_jobs "$root"
  job=$(mktemp -d "$root/job.XXXXXX")
  printf '%s\n' "$source" >"$job/source"
  echo 'Reading…' >"$job/status"
  # A process group of its own, so stop_old_jobs can stop the job and
  # everything it started with one kill. None of its streams is one of
  # Alfred's pipes, so Alfred does not wait for it.
  # shellcheck disable=SC2016 # Perl code, not shell
  "$PERL" -e 'setpgrp(0, 0); exec @ARGV or die "cannot run $ARGV[0]: $!\n"' \
    /bin/bash "$LIB_DIR/summarize.sh" --run "$job" </dev/null >/dev/null 2>"$job/job.err" &
  printf '%s\n' "$!" >"$job/pid"
  # Not render: until the launcher has started, the pid still shows this
  # script's command line, and render would take the job for dead.
  text_pl view-running "$job"
}

render() {
  local job="$1"
  if [ ! -d "$job" ]; then
    text_pl view-message "This summary is gone. Run it again from the keyword."
  elif [ -e "$job/done" ]; then
    text_pl view-final "$job"
    rm -rf "$job"
  elif job_running "$job" "$(cat "$job/pid" 2>/dev/null)"; then
    text_pl view-running "$job"
  else
    # The job ended without writing done: it got a KILL, or the launcher in
    # start_job could not start it. It may also have written done just now.
    if [ ! -e "$job/done" ] && [ ! -s "$job/msg" ]; then
      {
        echo 'Summarize stopped unexpectedly.'
        tail -n 3 "$job/job.err" 2>/dev/null
      } >"$job/msg"
    fi
    text_pl view-final "$job"
    # A KILL that ended the job also ended its timeout.pl, so the backend
    # may still run. Its record goes with the directory.
    [ -e "$job/done" ] || kill_backend "$job"
    rm -rf "$job"
  fi
}

view() {
  local root
  setup_env
  if [ -n "${sum_job:-}" ]; then
    root=$(jobs_dir)
    # render deletes a finished job, so it only gets a direct child of the
    # jobs directory. A stale or hand-set sum_job is "gone" instead.
    case "$sum_job" in
      "$root"/job.*/* | "$root"/job.) text_pl view-message "This summary is gone. Run it again from the keyword." ;;
      "$root"/job.*) render "$sum_job" ;;
      *) text_pl view-message "This summary is gone. Run it again from the keyword." ;;
    esac
  else
    start_job "${1:-}"
  fi
}

# ----------------------------------------------------------------- the job

JOB=""
CMD_DIR=""

# drop_content: deletes the files that hold the text the job read, or
# error output from reading it. Missing files are fine, so it can run twice.
drop_content() {
  rm -f "$JOB/clip" "$JOB/pbpaste.err" "$JOB/page" "$JOB/curl.err" "$JOB/osa.err" \
    "$JOB/input" "$JOB/input.cut"
}

# Runs on every exit of the job. A job that dies without saying why, for
# example on a bug that trips `set -u`, still ends with a message and the
# last lines of its own stderr, so the Text View never stays empty.
finish() {
  local rc=$?
  [ -n "$CMD_DIR" ] && rm -rf "$CMD_DIR"
  [ -d "$JOB" ] || return
  if [ "$rc" -ne 0 ] && [ ! -s "$JOB/msg" ]; then
    {
      printf 'Summarize stopped unexpectedly (exit code %s).\n' "$rc"
      tail -n 3 "$JOB/job.err" 2>/dev/null
    } >"$JOB/msg"
  fi
  drop_content
  rm -f "$JOB/err"
  : >"$JOB/done"
  # Only after done: a running view shows status while out is empty.
  rm -f "$JOB/status"
}

# fail MESSAGE: the job ends with MESSAGE as its only output line.
fail() {
  printf '%s\n' "$1" >"$JOB/msg"
  exit 0
}

status() { printf '%s\n' "$1" >"$JOB/status"; }

# need_count NAME VALUE MAX: VALUE must be a whole number from 1 to MAX.
# Comparing lengths first keeps a value past 64 bits away from `[ -gt ]`,
# which can't read it.
need_count() {
  case "$2" in
    '' | *[!0-9]* | 0 | 0*) fail "$1 must be a whole number of 1 or more (got \"$2\")." ;;
  esac
  if [ "${#2}" -gt "${#3}" ] || [ "$2" -gt "$3" ]; then
    fail "$1 must be $3 or less (got \"$2\")."
  fi
}

load_config() {
  SUM_COMMAND="${SUM_COMMAND-$DEFAULT_COMMAND}"
  SUM_MODEL="${SUM_MODEL:-sonnet}"
  SUM_LANGUAGE="${SUM_LANGUAGE:-}"
  SUM_MIN_BULLETS="${SUM_MIN_BULLETS:-3}"
  SUM_MAX_BULLETS="${SUM_MAX_BULLETS:-10}"
  SUM_PROMPT_OVERRIDE="${SUM_PROMPT_OVERRIDE:-}"
  SUM_MAX_CHARS="${SUM_MAX_CHARS:-200000}"
  SUM_TIMEOUT="${SUM_TIMEOUT:-120}"
  SUM_FETCH_TIMEOUT="${SUM_FETCH_TIMEOUT:-15}"
  SUM_APP_TIMEOUT="${SUM_APP_TIMEOUT:-60}"
  # The timeouts stop at 100000000 seconds, the most timeout.pl accepts.
  need_count SUM_MIN_BULLETS "$SUM_MIN_BULLETS" 100
  need_count SUM_MAX_BULLETS "$SUM_MAX_BULLETS" 100
  need_count SUM_MAX_CHARS "$SUM_MAX_CHARS" 10000000
  need_count SUM_TIMEOUT "$SUM_TIMEOUT" 100000000
  need_count SUM_FETCH_TIMEOUT "$SUM_FETCH_TIMEOUT" 100000000
  need_count SUM_APP_TIMEOUT "$SUM_APP_TIMEOUT" 100000000
  if [ "$SUM_MIN_BULLETS" -gt "$SUM_MAX_BULLETS" ]; then
    fail "SUM_MIN_BULLETS ($SUM_MIN_BULLETS) is larger than SUM_MAX_BULLETS ($SUM_MAX_BULLETS)."
  fi
  case "$SUM_COMMAND" in
    *[![:space:]]*) ;;
    *) fail "SUM_COMMAND is empty. Set it in the workflow's Configure Workflow screen." ;;
  esac
}

# ---- clipboard

read_clipboard() {
  local text host rc
  # Into a file first, so the exit code tells a hung pbpaste (124 from the
  # watchdog, with nothing on stderr) from one that failed.
  tool_run SUM_PBPASTE pbpaste "$SUM_APP_TIMEOUT" >"$JOB/clip" 2>"$JOB/pbpaste.err"
  rc=$?
  if [ "$rc" -eq 124 ]; then
    fail "The clipboard did not answer within $SUM_APP_TIMEOUT s (SUM_APP_TIMEOUT)."
  elif [ "$rc" -ne 0 ]; then
    fail "Could not read the clipboard: $(cat "$JOB/pbpaste.err")"
  fi
  text=$(text_pl trim <"$JOB/clip") ||
    fail "Could not read the clipboard: $(cat "$JOB/pbpaste.err")"
  [ -n "$text" ] || fail "Nothing to summarize."
  if host=$(printf '%s' "$text" | text_pl url-host); then
    fetch_page "$text" "$host"
  else
    printf '%s' "$text" >"$JOB/input"
  fi
}

# html_to_text [CHARSET]: HTML on stdin, plain text on stdout. Perl decodes
# the page with CHARSET, else the page's <meta> charset, else UTF-8, and
# removes scripts, styles, navigation and every tag that loads a resource.
# Then the built-in textutil does the actual conversion, entities and tables
# included. textutil alone waits up to a minute for a page's resources.
html_to_text() {
  text_pl strip-html "${1:-}" |
    tool_run SUM_TEXTUTIL textutil "${SUM_FETCH_TIMEOUT:-15}" -convert txt -format html \
      -inputencoding UTF-8 -stdin -stdout 2>/dev/null |
    text_pl clean-text
}

# fetch_page URL HOST: writes the page's text to input, or fails.
fetch_page() {
  local url="$1" host="$2" meta rc rip code ctype charset text chars
  status "Fetching ${host}…"
  meta=$(tool_run SUM_CURL curl "$SUM_FETCH_TIMEOUT" -q -sS -L --globoff \
    --proto =http,https --proto-redir =http,https --max-redirs 5 \
    --max-time "$SUM_FETCH_TIMEOUT" --max-filesize "$MAX_PAGE_BYTES" -A "$USER_AGENT" -o "$JOB/page" \
    -w '%{remote_ip}\n%{http_code}\n%{content_type}' "$url" 2>"$JOB/curl.err")
  rc=$?
  # 28 is curl's own --max-time; 124 is the watchdog catching a curl that
  # hangs anyway, for example in DNS.
  if [ "$rc" -eq 28 ] || [ "$rc" -eq 124 ]; then
    fail "Fetching $host timed out after $SUM_FETCH_TIMEOUT s (SUM_FETCH_TIMEOUT). $HINT_ACTIVE_WINDOW"
  elif [ "$rc" -ne 0 ]; then
    fail "Could not fetch $host: $(tr '\n' ' ' <"$JOB/curl.err" | sed 's/ *$//'). $HINT_ACTIVE_WINDOW"
  fi
  # remote_ip is the server of the last request, after any redirects. Checked
  # before the body is used, so a redirect into the local network is refused.
  # Earlier hops are not seen: a chain that passes an internal address and
  # ends on a public one is accepted. Only exit 0 from public-ip accepts the
  # page, so a crash of the helper refuses it too.
  rip=$(printf '%s\n' "$meta" | sed -n 1p)
  if ! printf '%s' "$rip" | text_pl public-ip; then
    fail "Refused to fetch $host: it leads to a private, loopback or link-local address (${rip:-unknown}). $HINT_ACTIVE_WINDOW"
  fi
  code=$(printf '%s\n' "$meta" | sed -n 2p)
  ctype=$(printf '%s\n' "$meta" | sed -n 3p | tr '[:upper:]' '[:lower:]')
  case "$code" in
    2??) ;;
    *) fail "$host answered with HTTP $code. $HINT_ACTIVE_WINDOW" ;;
  esac
  charset=$(printf '%s\n' "$ctype" | sed -n 's/.*charset="\{0,1\}\([A-Za-z0-9_.:-]*\).*/\1/p')
  case "$ctype" in
    '' | text/html* | application/xhtml*)
      text=$(html_to_text "$charset" <"$JOB/page")
      rc=$?
      # Without this, a failed conversion reads as a page with no text.
      if [ "$rc" -eq 124 ]; then
        fail "Converting the page at $host timed out after $SUM_FETCH_TIMEOUT s (SUM_FETCH_TIMEOUT). $HINT_ACTIVE_WINDOW"
      elif [ "$rc" -ne 0 ]; then
        fail "Could not convert the page at $host to text. $HINT_ACTIVE_WINDOW"
      fi
      ;;
    text/plain | text/plain[\;\ ]* | text/markdown | text/markdown[\;\ ]*)
      text=$(text_pl decode "$charset" <"$JOB/page" | text_pl clean-text) ;;
    *) fail "$host sent ${ctype%%;*}, not a web page. $HINT_ACTIVE_WINDOW" ;;
  esac
  chars=$(printf '%s' "$text" | text_pl count)
  if [ "$chars" -lt "$MIN_PAGE_CHARS" ]; then
    fail "The page at $host has too little text to summarize ($chars characters). $HINT_ACTIVE_WINDOW"
  fi
  printf 'URL: %s\n\n%s' "$url" "$text" >"$JOB/input"
}

# ---- active window

# apple_error RC APP SAFARI_OR_CHROMIUM: fails with the message that fits
# osascript's stderr in $JOB/osa.err. Matches error numbers and the words
# "JavaScript" plus "Apple Event", "Apple-Event" or "AppleScript", because
# macOS and the browsers translate the rest of the message into the system
# language.
apple_error() {
  local rc="$1" app="$2" kind="$3" err
  err=$(cat "$JOB/osa.err" 2>/dev/null)
  if [ "$rc" -eq 124 ]; then
    fail "$app did not answer within $SUM_APP_TIMEOUT s (SUM_APP_TIMEOUT)."
  elif [[ "$err" == *-1743* ]]; then
    fail "Alfred may not control $app. Allow it under System Settings > Privacy & Security > Automation."
  elif [[ "$err" == *JavaScript* ]] && [[ "$err" == *"Apple Event"* || "$err" == *AppleScript* || "$err" == *"Apple-Event"* ]]; then
    if [ "$kind" = safari ]; then
      fail "$app does not allow JavaScript from Apple Events. Turn on Develop > Developer Settings > Allow JavaScript from Apple Events."
    fi
    fail "$app does not allow JavaScript from Apple Events. Turn on View > Developer > Allow JavaScript from Apple Events."
  fi
  fail "Could not read $app: $(printf '%s' "$err" | tr '\n' ' ' | sed 's/ *$//')"
}

# JavaScript run in the page: the selection if there is one, else the page
# text. The first line says which.
PAGE_JS='(function(){var s=String(window.getSelection());if(s.trim())return "selection\n"+s;return "page\n"+(document.body?document.body.innerText:"")})()'

# browser_script BUNDLE_ID safari|chromium: the AppleScript that prints the
# tab's URL, title, "selection" or "page", then the text, one per line.
browser_script() {
  local id="$1" js
  js=${PAGE_JS//\\/\\\\}
  js=${js//\"/\\\"}
  if [ "$2" = safari ]; then
    printf '%s\n' "tell application id \"$id\"
  if (count of windows) is 0 then return \"none\"
  set t to current tab of front window
  set r to do JavaScript \"$js\" in t
  return (URL of t) & linefeed & (name of t) & linefeed & r
end tell"
  else
    printf '%s\n' "tell application id \"$id\"
  if (count of windows) is 0 then return \"none\"
  set t to active tab of front window
  set r to execute t javascript \"$js\"
  return (URL of t) & linefeed & (title of t) & linefeed & r
end tell"
  fi
}

read_browser() {
  local id="$1" app="$2" kind="$3" out rc url title what text
  status "Reading ${app}…"
  out=$(tool_run SUM_OSASCRIPT osascript "$SUM_APP_TIMEOUT" -e "$(browser_script "$id" "$kind")" 2>"$JOB/osa.err")
  rc=$?
  [ "$rc" -eq 0 ] || apple_error "$rc" "$app" "$kind"
  [ "$out" != none ] || fail "Nothing to summarize."
  url=$(printf '%s\n' "$out" | sed -n 1p)
  title=$(printf '%s\n' "$out" | sed -n 2p)
  what=$(printf '%s\n' "$out" | sed -n 3p)
  text=$(printf '%s\n' "$out" | sed '1,3d' | text_pl trim)
  [ -n "$text" ] || fail "Nothing to summarize."
  if [ "$what" = selection ]; then
    printf '%s' "$text" >"$JOB/input"
  else
    printf 'Title: %s\nURL: %s\n\n%s' "$title" "$url" "$text" >"$JOB/input"
  fi
}

# mail_script BUNDLE_ID: the AppleScript that prints 0, many, or 1 followed
# by the selected message's subject, sender and body, one per line.
mail_script() {
  printf '%s\n' "tell application id \"$1\"
  set sel to selection
  if (count of sel) is 0 then return \"0\"
  if (count of sel) > 1 then return \"many\"
  set m to item 1 of sel
  return \"1\" & linefeed & (subject of m) & linefeed & (sender of m) & linefeed & (content of m)
end tell"
}

read_mail() {
  local id="$1" app="$2" out rc subject sender body
  status "Reading ${app}…"
  out=$(tool_run SUM_OSASCRIPT osascript "$SUM_APP_TIMEOUT" -e "$(mail_script "$id")" 2>"$JOB/osa.err")
  rc=$?
  [ "$rc" -eq 0 ] || apple_error "$rc" "$app" mail
  case "$(printf '%s\n' "$out" | sed -n 1p)" in
    1) ;;
    many) fail "Select one message in $app. More than one is selected." ;;
    *) fail "Nothing to summarize." ;;
  esac
  subject=$(printf '%s\n' "$out" | sed -n 2p)
  sender=$(printf '%s\n' "$out" | sed -n 3p)
  body=$(printf '%s\n' "$out" | sed '1,3d' | text_pl trim)
  [ -n "$body" ] || fail "Nothing to summarize."
  printf 'Subject: %s\nFrom: %s\n\n%s' "$subject" "$sender" "$body" >"$JOB/input"
}

read_window() {
  local id="${sum_app_id:-}" app="${sum_app_name:-}"
  # The Script Filter saw the app while Alfred's bar was open and passes it
  # on. Ask again only when it did not, for example when run by hand.
  if [ -z "$id" ]; then
    front_app
    id="$APP_ID"
    app="$APP_NAME"
  fi
  [ -n "$app" ] || app="$id"
  [ -n "$id" ] || fail "Nothing to summarize."
  case "$(app_kind "$id")" in
    safari) read_browser "$id" "$app" safari ;;
    chromium) read_browser "$id" "$app" chromium ;;
    mail) read_mail "$id" "$app" ;;
    *) fail "Not supported in $app." ;;
  esac
}

# ---- the command

# Sets SUM_PROMPT: the override if there is one, else the bundled prompt.md,
# with the placeholders filled in.
build_prompt() {
  local template
  if [ -n "$SUM_PROMPT_OVERRIDE" ]; then
    template="$SUM_PROMPT_OVERRIDE"
  else
    template=$(cat "$WORKFLOW_DIR/prompt.md" 2>/dev/null) || fail "Could not read prompt.md."
  fi
  SUM_PROMPT=$(printf '%s' "$template" | text_pl fill-prompt "$SUM_MIN_BULLETS" "$SUM_MAX_BULLETS" "$SUM_LANGUAGE")
}

# The first word of SUM_COMMAND without its directory, to tell whether the
# backend is Claude Code and the login or update hint applies.
command_name() {
  local first
  read -r first _ <<<"$SUM_COMMAND"
  first="${first#\"}"
  first="${first%\"}"
  printf '%s\n' "${first##*/}"
}

run_command() {
  local rc err
  text_pl cut "$SUM_MAX_CHARS" <"$JOB/input" >"$JOB/input.cut"
  rc=$?
  if [ "$rc" -eq 10 ]; then
    printf 'Input cut to %s characters (SUM_MAX_CHARS).\n' "$SUM_MAX_CHARS" >"$JOB/notice"
  elif [ "$rc" -ne 0 ]; then
    fail "Could not prepare the input for the command."
  fi
  mv "$JOB/input.cut" "$JOB/input"
  build_prompt
  export SUM_PROMPT SUM_MODEL
  status "Summarizing…"
  # An empty directory as the working directory, so a backend that looks
  # around (Claude Code reads CLAUDE.md files) finds nothing to read.
  CMD_DIR=$(mktemp -d)
  # The command reads input through the open stdin, so the file can go
  # before the command starts.
  {
    drop_content
    (cd "$CMD_DIR" && SUM_PGID_FILE="$JOB/backend.pgid" exec "$PERL" "$LIB_DIR/timeout.pl" "$SUM_TIMEOUT" /bin/zsh -c "$SUM_COMMAND") \
      >"$JOB/out" 2>"$JOB/err"
  } <"$JOB/input"
  rc=$?
  if [ "$rc" -eq 124 ]; then
    fail "The command timed out after $SUM_TIMEOUT s (SUM_TIMEOUT)."
  elif [ "$rc" -ne 0 ]; then
    err=$(text_pl trim <"$JOB/err" | text_pl cut 2000)
    {
      printf 'The command failed with exit code %s.\n' "$rc"
      [ -z "$err" ] || printf '%s\n' "$err"
      [ "$(command_name)" != claude ] || printf '%s\n' "$HINT_LOGIN"
    } >"$JOB/msg"
    exit 0
  fi
  if [ -z "$(text_pl trim <"$JOB/out")" ]; then
    fail "The command returned no summary."
  fi
}

run_job() {
  JOB="$1"
  [ -d "$JOB" ] || exit 1
  trap finish EXIT
  # Bash runs a TERM trap only after the current foreground command ends.
  # timeout.pl passes the TERM on to the backend and exits once the backend
  # has died, so a backend that ignores TERM holds the job until timeout.pl
  # sends KILL a few seconds later.
  trap 'exit 143' TERM
  setup_env
  load_config
  case "$(cat "$JOB/source")" in
    clipboard) read_clipboard ;;
    window) read_window ;;
  esac
  run_command
}

main() {
  if [ "${1:-}" = "--run" ]; then
    run_job "${2:-}"
  else
    view "${1:-}"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
