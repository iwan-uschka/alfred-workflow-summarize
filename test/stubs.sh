#!/bin/bash
# Stubs for the external tools, shared by the flow tests. Source it after
# setting ROOT. Every stub is a plain bash file run as `/bin/bash <file>`
# through the SUM_* override variables, so none needs an execute bit and
# none touches the real clipboard, apps or network.
#
# Each stub appends one line per call to $STUB_LOG, so tests can assert what
# was and was not called.

# Start from the workflow's defaults, whatever the caller's shell exports
# (reset_test_env in test/helpers.sh, which the caller sources first). The
# stub selection variables are set again below.
reset_test_env

STUBS=$(mktemp -d)
trap 'rm -rf "$STUBS"' EXIT
export STUB_LOG="$STUBS/calls.log"

# pbpaste: prints $STUB_CLIP_FILE. STUB_PBPASTE_FAIL=1 fails instead;
# STUB_PBPASTE_HANG=1 sleeps.
cat >"$STUBS/pbpaste" <<'STUB'
echo "pbpaste" >>"$STUB_LOG"
[ "${STUB_PBPASTE_HANG:-0}" = 1 ] && sleep 30
if [ "${STUB_PBPASTE_FAIL:-0}" = 1 ]; then
  echo "pbpaste: no pasteboard" >&2
  exit 1
fi
cat "$STUB_CLIP_FILE"
STUB

# lsappinfo: the front app is $STUB_APP_ID named $STUB_APP_NAME; an empty
# STUB_APP_ID means no front app. STUB_LSAPPINFO_FAIL=1 fails every call.
cat >"$STUBS/lsappinfo" <<'STUB'
echo "lsappinfo $1" >>"$STUB_LOG"
[ "${STUB_LSAPPINFO_FAIL:-0}" = 1 ] && exit 1
case "$1" in
  front) [ -n "${STUB_APP_ID:-}" ] && echo "ASN:0x0-0x1234:" ;;
  info)
    if [ -n "${STUB_APP_ID:-}" ]; then
      echo "\"CFBundleIdentifier\"=\"$STUB_APP_ID\""
      echo "\"LSDisplayName\"=\"$STUB_APP_NAME\""
    fi
    ;;
esac
exit 0
STUB

# osascript: saves the script to $STUBS/last.applescript, then prints
# $STUB_OSA_OUT_FILE and exits 0. STUB_OSA_ERR (stderr text) with
# STUB_OSA_RC fails instead; STUB_OSA_HANG=1 sleeps.
cat >"$STUBS/osascript" <<'STUB'
echo "osascript" >>"$STUB_LOG"
printf '%s' "$2" >"$(dirname "$STUB_LOG")/last.applescript"
[ "${STUB_OSA_HANG:-0}" = 1 ] && sleep 30
if [ -n "${STUB_OSA_ERR:-}" ]; then
  echo "$STUB_OSA_ERR" >&2
  exit "${STUB_OSA_RC:-1}"
fi
cat "$STUB_OSA_OUT_FILE"
STUB

# curl: writes $STUB_PAGE to the -o file and prints "$STUB_REMOTE_IP" (public
# by default), "$STUB_HTTP_CODE" and "$STUB_CTYPE" on three lines, like the
# -w format summarize.sh passes.
# STUB_CURL_RC with STUB_CURL_ERR fails instead; STUB_CURL_HANG=1 sleeps
# and ignores --max-time.
cat >"$STUBS/curl" <<'STUB'
echo "curl $*" >>"$STUB_LOG"
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
  esac
  shift
done
[ "${STUB_CURL_HANG:-0}" = 1 ] && sleep 30
if [ -n "${STUB_CURL_RC:-}" ]; then
  echo "curl: ${STUB_CURL_ERR:-failed}" >&2
  exit "$STUB_CURL_RC"
fi
cp "$STUB_PAGE" "$out"
printf '%s\n%s\n%s' "${STUB_REMOTE_IP-93.184.216.34}" "${STUB_HTTP_CODE:-200}" "${STUB_CTYPE-text/html; charset=utf-8}"
STUB

# The backend. Logs its stdin, working directory, the directory's contents
# and the two variables, then answers by $STUB_CMD_MODE:
#   ok (default)  prints a two-line summary
#   fail          prints to stderr and exits 3
#   hang          records its pid in $STUBS/cmd.pid and sleeps
#   empty         prints nothing
cat >"$STUBS/cmd" <<'STUB'
d=$(dirname "$STUB_LOG")
echo "cmd" >>"$STUB_LOG"
cat >"$d/cmd.stdin"
pwd >"$d/cmd.pwd"
ls -A >"$d/cmd.ls"
printf '%s' "$SUM_PROMPT" >"$d/cmd.prompt"
printf '%s' "$SUM_MODEL" >"$d/cmd.model"
case "${STUB_CMD_MODE:-ok}" in
  fail)
    echo "stub: not logged in" >&2
    exit 3
    ;;
  hang)
    echo $$ >"$d/cmd.pid"
    sleep 30
    ;;
  empty) ;;
  *) printf 'TL;DR: stub summary.\n\n- first point\n' ;;
esac
STUB

export SUM_PBPASTE="/bin/bash $STUBS/pbpaste"
export SUM_LSAPPINFO="/bin/bash $STUBS/lsappinfo"
export SUM_OSASCRIPT="/bin/bash $STUBS/osascript"
export SUM_CURL="/bin/bash $STUBS/curl"
export SUM_COMMAND="/bin/bash $STUBS/cmd"
export STUB_CLIP_FILE="$STUBS/clip" STUB_OSA_OUT_FILE="$STUBS/osa.out" STUB_PAGE="$STUBS/page.html"

# clip TEXT: sets the stub clipboard (printf %s, so no trailing newline).
clip() { printf '%s' "$1" >"$STUB_CLIP_FILE"; }

# front ID NAME: sets the stub frontmost app; front "" means none.
front() {
  export STUB_APP_ID="$1" STUB_APP_NAME="${2:-}"
}

reset_stubs() {
  : >"$STUB_LOG"
  rm -f "$STUBS"/cmd.* "$STUBS/last.applescript"
  unset STUB_PBPASTE_FAIL STUB_PBPASTE_HANG STUB_LSAPPINFO_FAIL STUB_OSA_ERR STUB_OSA_RC STUB_OSA_HANG \
    STUB_CURL_RC STUB_CURL_ERR STUB_CURL_HANG STUB_REMOTE_IP STUB_HTTP_CODE STUB_CTYPE STUB_CMD_MODE
  clip ""
  front ""
  : >"$STUB_OSA_OUT_FILE"
}
reset_stubs
