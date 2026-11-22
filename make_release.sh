#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Usage: bash make_release.sh <version>
if [ -z "${1:-}" ]; then
  echo "error: version required. Usage: bash make_release.sh 1.2.0"
  exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
BUILT="dist/Summarize.alfredworkflow"
RELEASE="dist/Summarize-${TAG}.alfredworkflow"
ASSET="$(basename "${RELEASE}")"
NOTES_FILE="${RELEASE%.alfredworkflow}.notes.md"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be x.y.z (got '${VERSION}')"
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is not clean. Commit or stash changes before releasing"
  exit 1
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "error: tag ${TAG} already exists locally"
  exit 1
fi

if ! remote_tag_check="$(git ls-remote --tags origin "refs/tags/${TAG}" 2>&1)"; then
  echo "error: could not check origin for existing tags: ${remote_tag_check}"
  exit 1
fi
if [ -n "$remote_tag_check" ]; then
  echo "error: tag ${TAG} already exists on origin"
  exit 1
fi

# The release notes are CHANGELOG.md's "## <version>" section: every line up
# to the next "## " heading, without leading and trailing blank lines or CRLF
# line ends. The heading has to be the whole line, so "## 1.0.10" is no entry
# for 1.0.1.
NOTES=""
if [ -f CHANGELOG.md ]; then
  NOTES="$(awk -v heading="## ${VERSION}" '
    { sub(/\r$/, "") }
    $0 == heading { found = 1; next }
    found && /^## / { exit }
    found && /^[[:space:]]*$/ { if (started) blanks = blanks $0 "\n"; next }
    found { printf "%s", blanks; blanks = ""; started = 1; print }
  ' CHANGELOG.md)"
fi
if [ -z "$NOTES" ]; then
  echo "error: CHANGELOG.md has no entry for ${VERSION}. Add a '## ${VERSION}' section with at least one line before releasing"
  exit 1
fi

# Without --target, gh creates a new tag at the remote default branch, which
# lacks the version bump when this runs on another branch.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

echo "-> Version: ${VERSION} (tag: ${TAG})"

# Bump the root-level version key in info.plist, restoring it if anything
# downstream fails. The keypath has no dots, so plutil targets only the
# top-level key (not the nested per-object version keys). The same trap
# removes the build and any half-written versioned artifact, so a failed run
# leaves no release file claiming a version info.plist no longer carries.
BACKUP="$(mktemp)"
cp info.plist "$BACKUP"
trap 'cp "$BACKUP" info.plist; rm -f "$BACKUP" "$BUILT" "$RELEASE" "${RELEASE}.sha256" "$NOTES_FILE"' EXIT

plutil -replace version -string "${VERSION}" info.plist
plutil -lint info.plist

echo "-> Building workflow..."
bash ./build.sh >/dev/null

echo "-> Packaging ${RELEASE}..."
rm -f "${RELEASE}" "${RELEASE}.sha256" "${NOTES_FILE}"
cp "${BUILT}" "${RELEASE}"
# dist/ is ignored by git, so the notes file never shows up as a change.
printf '%s\n' "$NOTES" > "${NOTES_FILE}"
# Run shasum from inside dist/, so the checksum file records the bare asset
# name. Release assets download flat, and `shasum -c` looks the recorded path
# up relative to the current directory, and a `dist/` prefix would never match.
# The file itself still lands at "${RELEASE}.sha256".
(cd dist && shasum -a 256 "${ASSET}" > "${ASSET}.sha256")

# Bump succeeded end-to-end, so keep the info.plist change.
trap - EXIT
rm -f "$BACKUP"

echo ""
echo "Done: ${RELEASE} is ready ($(du -sh "${RELEASE}" | cut -f1))"
echo "  SHA-256: $(cut -d' ' -f1 "${RELEASE}.sha256")"
echo ""
echo "Next steps:"
echo ""
echo "  1. Commit and push the version bump:"
echo "     git add info.plist && git commit -m 'Release ${VERSION}' && git push"
echo ""
echo "  2. Create the GitHub release:"
echo "     gh release create ${TAG} ${RELEASE} ${RELEASE}.sha256 \\"
echo "       --target \"${BRANCH}\" \\"
echo "       --title \"Summarize ${VERSION}\" \\"
echo "       --notes-file ${NOTES_FILE}"
