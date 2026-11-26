# Changelog

Each release has a `## <version>` section. `make_release.sh` refuses to
release a version without one and uses that section as the release notes.

## Unreleased

## 0.2.0

- The number of summary bullets now follows the length of the text, so a short text no longer gets the maximum.
- Markdown images, links and HTML tags in the summary are reduced to plain text, so the output loads nothing remote.
- Downloaded pages are decoded with their declared charset, and pages wrapped in a `<form>` keep their text.
- Only `text/plain` and `text/markdown` count as plain text, so other `text/*` types such as CSS get the "not a web page" message.
- The text that was read is deleted from the job directory as soon as the command has it.
- Starting a new summary stops the old job reliably, and a job that died shows a message instead of an empty view.
- Out-of-range numeric settings are bounded instead of breaking the run.

## 0.1.0

- The `sum` keyword summarizes the active window or the clipboard in an Alfred Text View.
- A clipboard that holds a single URL makes the workflow download that page and summarize its text.
- A configurable command produces the summary, `claude -p` by default.
