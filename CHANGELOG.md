# Changelog

Each release has a `## <version>` section. `make_release.sh` refuses to
release a version without one and uses that section as the release notes.

## Unreleased

- The number of summary bullets now follows the length of the text, so a short text no longer gets the maximum.

## 0.1.0

- The `sum` keyword summarizes the active window or the clipboard in an Alfred Text View.
- A clipboard that holds a single URL makes the workflow download that page and summarize its text.
- A configurable command produces the summary, `claude -p` by default.
