#!/bin/bash
# Packaging tests for build.sh. Each case stages a copy of the files the
# script packages in a temp dir and runs the real build.sh from there, so no
# test writes to the repo's own dist/ or needs an icon.png in the repo root.
# The missing-tool cases run with a PATH holding only the tools build.sh
# needs, minus the one under test.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="dist/Summarize.alfredworkflow"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=test/helpers.sh
source "$ROOT/test/helpers.sh"

# stage <name>: a fresh copy of build.sh and everything it packages; prints
# the staged directory.
stage() {
  local dir="$WORK/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$ROOT/build.sh" "$ROOT/info.plist" "$ROOT/prompt.md" "$dir/"
  cp -R "$ROOT/scripts" "$dir/scripts"
  # start without execute bits so the test proves build.sh sets them
  chmod -x "$dir"/scripts/*.sh "$dir"/scripts/*.pl
  printf '%s\n' "$dir"
}

# --- default build: info.plist and scripts/ in the archive, no icon ---
dir=$(stage plain)
mkdir -p "$dir/test" && printf 'x\n' > "$dir/test/x.test.sh"
out=$(bash "$dir/build.sh" 2>&1)
code=$?
assert_eq "build exit code" "0" "$code"
listing=$(unzip -l "$dir/$OUT")
for f in info.plist prompt.md scripts/rows.sh scripts/summarize.sh scripts/lib.sh scripts/text.pl scripts/timeout.pl; do
  assert_contains "archive holds $f" "$listing" "$f"
done
refute_contains "no icon.png when the repo has none" "$listing" "icon.png"
refute_contains "no tests in the archive" "$listing" "test/"
# The Text View runs summarize.sh as a file, so the archive must keep its
# execute bit.
mode=$(zipinfo "$dir/$OUT" scripts/summarize.sh | awk '{print $1}')
# breaks-if: build.sh stops setting the execute bit before zipping
assert_eq "summarize.sh is executable inside the archive" "x" "$(printf '%s' "$mode" | cut -c4)"
# The archive unpacks to a workflow whose plist is valid.
mkdir -p "$dir/unpacked"
(cd "$dir/unpacked" && unzip -q "../$OUT")
plutil -lint "$dir/unpacked/info.plist" >/dev/null
assert_eq "unpacked info.plist lints" "0" "$?"
assert_eq "unpacked Script Filter rows run" "Active window|Clipboard" \
  "$(cd "$dir/unpacked" && SUM_PBPASTE=true SUM_LSAPPINFO=true /bin/bash ./scripts/rows.sh "" |
    /usr/bin/perl -MJSON::PP -e 'local $/; print join "|", map { $_->{title} } @{decode_json(<STDIN>)->{items}}')"

# --- Finder's .DS_Store files stay out of the archive ---
dir=$(stage dsstore)
printf 'finder\n' > "$dir/scripts/.DS_Store"
bash "$dir/build.sh" >/dev/null 2>&1
assert_eq "build with a .DS_Store exit code" "0" "$?"
# breaks-if: build.sh stops excluding .DS_Store from the zip
listing=$(unzip -l "$dir/$OUT")
refute_contains "no .DS_Store in the archive" "$listing" ".DS_Store"
assert_contains "the scripts next to the .DS_Store are packaged" "$listing" "scripts/summarize.sh"

# --- icon.png is packaged only when it exists ---
dir=$(stage icon)
printf 'not really a png\n' > "$dir/icon.png"
bash "$dir/build.sh" >/dev/null 2>&1
assert_eq "build with icon exit code" "0" "$?"
assert_contains "icon.png is packaged when present" "$(unzip -l "$dir/$OUT")" "icon.png"

# --- no scripts at all: the glob guard keeps the build alive ---
dir=$(stage noscripts)
rm -f "$dir"/scripts/*.sh "$dir"/scripts/*.pl
printf 'readme\n' >"$dir/scripts/notes.txt"
out=$(bash "$dir/build.sh" 2>&1)
# breaks-if: the nullglob guard goes and chmod gets the literal pattern
assert_eq "build without any script exit code" "0" "$?"
refute_contains "no chmod error about the unexpanded glob" "$out" "scripts/*.sh"
assert_contains "the rest is still packaged" "$(unzip -l "$dir/$OUT")" "scripts/notes.txt"

# --- rebuild replaces the archive rather than adding to it ---
dir=$(stage rebuild)
printf '#!/bin/bash\n' > "$dir/scripts/stale.sh"
bash "$dir/build.sh" >/dev/null 2>&1
assert_contains "first build packages the extra script" "$(unzip -l "$dir/$OUT")" "scripts/stale.sh"
rm -f "$dir/scripts/stale.sh"
bash "$dir/build.sh" >/dev/null 2>&1
refute_contains "rebuild drops a file that is gone" "$(unzip -l "$dir/$OUT")" "scripts/stale.sh"

# --- missing zip / unzip: named ERROR, no archive written ---
# bin <name>...: a PATH dir holding only the named tools
bin() {
  local dir="$WORK/bin-$1" t
  shift
  rm -rf "$dir"
  mkdir -p "$dir"
  for t in "$@"; do ln -s "$(command -v "$t")" "$dir/$t"; done
  printf '%s\n' "$dir"
}
COMMON=(bash dirname chmod mkdir rm)

dir=$(stage nozip)
# breaks-if: the zip check at the top of build.sh is removed
out=$(PATH="$(bin nozip "${COMMON[@]}" unzip)" bash "$dir/build.sh" 2>&1)
assert_eq "missing zip exit code" "1" "$?"
assert_contains "missing zip message" "$out" "ERROR: zip not found on PATH"
refute_file "missing zip writes no archive" "$dir/$OUT"

dir=$(stage nounzip)
# breaks-if: the unzip check at the top of build.sh is removed
out=$(PATH="$(bin nounzip "${COMMON[@]}" zip)" bash "$dir/build.sh" 2>&1)
assert_eq "missing unzip exit code" "1" "$?"
assert_contains "missing unzip message" "$out" "ERROR: unzip not found on PATH"
refute_file "missing unzip writes no archive" "$dir/$OUT"

# --- missing prompt.md: named ERROR, no archive written ---
dir=$(stage noprompt)
rm -f "$dir/prompt.md"
# breaks-if: the required-file check in build.sh is removed
out=$(bash "$dir/build.sh" 2>&1)
assert_eq "missing prompt.md exit code" "1" "$?"
assert_contains "missing prompt.md message" "$out" "ERROR: prompt.md not found"
refute_file "missing prompt.md writes no archive" "$dir/$OUT"

# --- missing info.plist: named ERROR, no archive written ---
dir=$(stage noplist)
rm -f "$dir/info.plist"
# breaks-if: info.plist drops out of the required-file check in build.sh
out=$(bash "$dir/build.sh" 2>&1)
assert_eq "missing info.plist exit code" "1" "$?"
assert_contains "missing info.plist message" "$out" "ERROR: info.plist not found"
refute_file "missing info.plist writes no archive" "$dir/$OUT"

finish_tests
