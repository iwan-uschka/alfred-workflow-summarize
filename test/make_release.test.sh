#!/bin/bash
# Guard and rollback tests for make_release.sh. Each case gets its own throw-
# away git repo in a temp dir, with a local bare repo as `origin`, so the
# remote-tag checks run against real git without touching the network or this
# repo. git, plutil, zip and shasum are the real ones; only the shasum-failure
# case replaces shasum, with an exported shell function, which the release
# script's bash picks up before PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=test/helpers.sh
source "$ROOT/test/helpers.sh"

# new_repo <name>: a committed copy of the release inputs with a local bare
# origin; prints the repo directory.
new_repo() {
  local dir="$WORK/repo-$1" origin="$WORK/origin-$1.git"
  rm -rf "$dir" "$origin"
  mkdir -p "$dir"
  cp "$ROOT/make_release.sh" "$ROOT/build.sh" "$ROOT/info.plist" "$ROOT/prompt.md" "$ROOT/.gitignore" "$dir/"
  cp -R "$ROOT/scripts" "$dir/scripts"
  git init -q -b main "$dir"
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name "Release Test"
  git -C "$dir" config commit.gpgsign false
  commit_all "$dir" "initial"
  git init -q --bare -b main "$origin"
  git -C "$dir" remote add origin "$origin"
  printf '%s\n' "$dir"
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
}

plist_version() { plutil -extract version raw -o - "$1/info.plist"; }

# run_release <dir> [version]: sets out and code
STUB_PATH="$PATH"
run_release() {
  out=$(PATH="$STUB_PATH" bash "$1/make_release.sh" ${2+"$2"} 2>&1)
  code=$?
}

ASSET="Summarize-v1.2.0.alfredworkflow"

# --- argument guards ---
dir=$(new_repo args)
BASE_VERSION=$(plist_version "$dir")
# breaks-if: the missing-version guard is removed
run_release "$dir"
assert_eq "missing version exit code" "1" "$code"
assert_contains "missing version message" "$out" "error: version required"

# breaks-if: the x.y.z format check is removed
run_release "$dir" 1.2
assert_eq "two-part version exit code" "1" "$code"
assert_contains "two-part version message" "$out" "error: version must be x.y.z (got '1.2')"
assert_eq "rejected version leaves info.plist alone" "$BASE_VERSION" "$(plist_version "$dir")"

# --- dirty working tree ---
dir=$(new_repo dirty)
printf 'scratch\n' > "$dir/scratch.txt"
# breaks-if: the clean-tree guard is removed
run_release "$dir" 1.2.0
assert_eq "dirty tree exit code" "1" "$code"
assert_contains "dirty tree message" "$out" "error: working tree is not clean"

# --- tag already exists locally ---
dir=$(new_repo localtag)
git -C "$dir" tag v1.2.0
# breaks-if: the local tag guard is removed
run_release "$dir" 1.2.0
assert_eq "local tag exit code" "1" "$code"
assert_contains "local tag message" "$out" "error: tag v1.2.0 already exists locally"

# --- tag already exists on origin (but not locally) ---
dir=$(new_repo remotetag)
git -C "$dir" tag v1.2.0
git -C "$dir" push -q origin v1.2.0
git -C "$dir" tag -d v1.2.0 >/dev/null
# breaks-if: the remote tag guard is removed
run_release "$dir" 1.2.0
assert_eq "remote tag exit code" "1" "$code"
assert_contains "remote tag message" "$out" "error: tag v1.2.0 already exists on origin"

# --- origin unreachable: the ls-remote failure is surfaced, not ignored ---
dir=$(new_repo noorigin)
git -C "$dir" remote set-url origin "$WORK/missing.git"
# breaks-if: a failing git ls-remote is read as "no such tag"
run_release "$dir" 1.2.0
assert_eq "unreachable origin exit code" "1" "$code"
assert_contains "unreachable origin message" "$out" "error: could not check origin for existing tags"

# --- happy path: version bumped, artifact and a verifiable checksum ---
dir=$(new_repo ok)
run_release "$dir" 1.2.0
assert_eq "release exit code" "0" "$code"
assert_eq "info.plist version bumped" "1.2.0" "$(plist_version "$dir")"
assert_file "versioned artifact written" "$dir/dist/$ASSET"
assert_file "checksum written" "$dir/dist/$ASSET.sha256"
assert_eq "checksum records the bare asset name" "$ASSET" \
  "$(awk '{print $2}' "$dir/dist/$ASSET.sha256")"
if (cd "$dir/dist" && shasum -c "$ASSET.sha256" >/dev/null 2>&1); then
  ok
else
  not_ok "shasum -c should verify the asset next to its checksum file"
fi
assert_contains "next steps name the tag" "$out" "gh release create v1.2.0"

# --- build.sh fails: info.plist restored, no versioned artifact left ---
dir=$(new_repo buildfail)
printf '#!/bin/bash\nexit 1\n' > "$dir/build.sh"
commit_all "$dir" "break the build"
# breaks-if: the EXIT trap stops restoring info.plist
run_release "$dir" 1.2.0
assert_eq "build failure exit code" "1" "$code"
assert_eq "build failure restores info.plist" "$BASE_VERSION" "$(plist_version "$dir")"
refute_file "build failure leaves no artifact" "$dir/dist/$ASSET"

# --- shasum fails after the copy: the artifact is cleaned up too ---
dir=$(new_repo shasumfail)
# shellcheck disable=SC2329 # called by make_release.sh through export -f
shasum() { return 1; }
export -f shasum
run_release "$dir" 1.2.0
unset -f shasum
# breaks-if: the EXIT trap in make_release.sh stops removing the artifact
assert_eq "shasum failure exit code" "1" "$code"
assert_eq "shasum failure restores info.plist" "$BASE_VERSION" "$(plist_version "$dir")"
refute_file "shasum failure leaves no artifact" "$dir/dist/$ASSET"
refute_file "shasum failure leaves no checksum" "$dir/dist/$ASSET.sha256"

finish_tests
