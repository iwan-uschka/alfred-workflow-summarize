# AGENTS.md

Guidance for coding agents working on this repo.

## What this is

An Alfred 5.5 workflow that summarizes the active window or the clipboard.
The keyword (default `sum`) opens a Script Filter with two rows, "Active
window" then "Clipboard". Enter opens a Text View that shows the summary as a
configurable command produces it. The default command is `claude -p`.

```
sum [filter]  ->  Script Filter (rows.sh)  ->  Text View, script input (summarize.sh, rerun loop)
                                                   \-> background job: read source -> SUM_COMMAND
```

## Layout

- `info.plist`: the Script Filter, the Text View, the Configure Workflow
  fields and the hidden advanced variables.
- `prompt.md`: the bundled prompt. `{min_bullets}`, `{max_bullets}` and
  `{language}` are filled in before it reaches the command.
- `scripts/lib.sh`: shared setup. PATH, locale, the frontmost app via
  `lsappinfo`, the app allowlist (`app_kind`), the default command, and
  `tool_run`, which runs every external tool under a timeout.
- `scripts/rows.sh`: the Script Filter.
- `scripts/summarize.sh`: the Text View script and the background job.
- `scripts/text.pl`: text helpers in core Perl. Trimming, URL detection,
  the clipboard preview, cutting to a length in characters, HTML stripping,
  prompt filling, and all JSON output.
- `scripts/timeout.pl`: `timeout(1)` for macOS. Exit 124 on timeout, kills
  the command's whole process group, passes a TERM on to that group.
- `test/`: shell tests, see below. `test/fixtures/` holds small hand-written
  HTML pages.
- `build.sh`, `make_release.sh`: packaging and releases.

## How the Text View streams

Alfred 5.5 streams into a Text View by rerunning its script, the same way a
Script Filter reruns. The Text View's input is "Script", pointing at
`scripts/summarize.sh`. Each run prints one JSON object with `response`, and
while the job runs also `rerun` (0.3 s) plus a `sum_job` variable. Alfred
passes `sum_job` back on the next run. Alfred's own ChatGPT workflow streams
the same way.

1. First run, no `sum_job`: `summarize.sh window|clipboard` makes a job
   directory under `$alfred_workflow_cache/jobs/`, starts
   `summarize.sh --run <job>` detached in its own process group, and renders
   the job.
2. Each rerun: render the job. While it runs, the response is the cut notice
   plus the command's stdout so far, or a status line before there is any.
3. Once the job wrote `done`: render the final text without `rerun`, set
   `sum_job` to empty, and delete the job directory.
4. A job that ended without `done`, because it got a KILL or the launcher
   could not start it, ends the same way, with "Summarize stopped
   unexpectedly." and the last lines of `job.err`. A job counts as running
   only while its pid still runs `summarize.sh --run <job>`. A KILL from
   outside also kills the job's `timeout.pl`, so a backend running at that
   moment keeps running, and nothing stops it.

Starting a job stops every older job first (`stop_old_jobs`), so closing the
Text View mid-run and starting again never leaves a backend running. It
sends a TERM to the old job's process group, waits up to 5 seconds for the
job to end, then sends a KILL if it is still running, and only then deletes
the directory. The job's EXIT trap writes into that directory while it ends.

The Text View's `behaviour`, `outputmode` and `scriptinput` values in
`info.plist` are copied from Alfred's own ChatGPT workflow, which uses the
same script-input Text View. Alfred does not document these numbers.

## Backend contract

- `SUM_COMMAND` is a string run by `/bin/zsh -c`, with an empty temporary
  directory (`mktemp -d`) as its working directory. The job deletes that
  directory when it ends.
- stdin: the text, already cut to `SUM_MAX_CHARS` characters. stdout: the
  summary, shown as it arrives. A non-zero exit shows the exit code and
  stderr, plus a login hint when the command's first word, without its
  directory, is `claude`.
- Environment: `SUM_MODEL` and `SUM_PROMPT` (the finished prompt), on top of
  the workflow's variables. PATH has `/opt/homebrew/bin`, `/usr/local/bin`,
  `~/.local/bin`, `~/.claude/local`, `~/.npm-global/bin`, `~/.volta/bin` and
  `$NPM_CONFIG_PREFIX/bin` in front, where they exist.
- Limits: `SUM_TIMEOUT` for the command, `SUM_FETCH_TIMEOUT` for the page
  download and its conversion, `SUM_APP_TIMEOUT` for each AppleScript call
  and for reading the clipboard.

## Design decisions

- **Strict allowlist.** Active window reads Safari, Chrome, Brave and Mail,
  by exact bundle id in `app_kind`, and nothing else. It is not configurable.
  Every other app gets "Not supported in <app>." before any AppleScript or
  backend call. A configurable list would let the workflow send content from
  apps nobody checked to a remote model, and each app needs its own
  AppleScript anyway.
- **Fixed row order.** The items have no `uid`, so Alfred never reorders
  them by usage, and `alfredfiltersresults` is off. `text.pl items` filters
  by case-insensitive substring itself, which also covers prefixes.
- **No typed input.** The query only filters the two rows. A typed text is
  never summarized. The Text View's own input field reruns the script with
  the typed text, and an unknown argument only shows a hint.
- **The command is a string.** Users paste a shell line they already run in
  a terminal, with quotes and variables. zsh, the macOS login shell, runs it,
  so `$SUM_MODEL` and `$SUM_PROMPT` expand there, pipes work, and any
  backend that reads stdin fits.
- **The app is seen while the Script Filter runs.** `lsappinfo front` needs
  no Automation permission and still reports the user's app while Alfred's
  bar is open. The rows pass `sum_app_id` and `sum_app_name` on to the Text
  View, so the job reads the app the user saw in the subtitle.
- **Building rows stays fast.** `rows.sh` calls only `pbpaste` and
  `lsappinfo`: no AppleScript, no network, no backend. It prints valid JSON
  and exits 0 even when those fail.
- **Failures are messages.** The job never exits with an empty Text View.
  `fail` writes one line to `msg`, and the EXIT trap writes a message with
  the job's last stderr lines when the job dies on its own.
- **Error detection survives translation.** macOS and the browsers translate
  AppleScript errors. `apple_error` matches the error number `-1743` and
  the words `JavaScript` plus `Apple Event`, `Apple-Event` or `AppleScript`,
  not whole English sentences.
- **HTML to text.** `textutil` alone waits up to 60 seconds for a real
  page's images and stylesheets and then fails. `text.pl strip-html` first
  removes comments, `head`, `script`, `style`, `nav`, `aside`, `footer`,
  forms and media, plus every tag that loads a resource. A page with exactly
  one `<main>` keeps only that. Then `textutil` converts the rest, entities
  and tables included. A fetched page with under 200 characters of text is
  refused.
- **Core tools only.** macOS ships everything the workflow runs: bash 3.2,
  `/usr/bin/perl` with core modules, `curl`, `textutil`, `osascript`.

## Conventions

- Bash 3.2: no `mapfile`, no associative arrays, guard empty arrays under
  `set -u`. Write `${var}…`, not `$var…`: bash 3.2 reads the first byte of
  `…` as part of the variable name.
- `rows.sh` and `summarize.sh` can be sourced; `main` runs only when the
  file is executed. Tests source them to call single functions.
- Keep logic in `scripts/`. `info.plist` only runs
  `/bin/bash ./scripts/rows.sh "$1"` and points the Text View at
  `scripts/summarize.sh`.
- Prose in docs, comments and messages: plain words, active voice, whole
  sentences, no em dashes, sentence-case headings, straight quotes.
- This repo names no other local repo or directory, in files or in commit
  messages. Describe a pattern instead of pointing at where it came from.
- Lint: `shellcheck -x scripts/*.sh test/*.sh build.sh make_release.sh`.
- After editing `info.plist`: `plutil -lint info.plist`.

## Tests

Run all of them:

```
for t in test/*.test.sh; do bash "$t" || exit 1; done
```

- `test/rows.test.sh`: the Script Filter. Row order, subtitles per app and
  clipboard kind, the 60-character preview boundary, filtering, valid JSON
  when tools fail, and the plist wiring of the keyword.
- `test/summarize.test.sh`: the Text View flow. Each case runs the rerun
  loop like Alfred until the output has no `rerun`. Covers every source,
  every failure message, the size limit, the timeouts, prompt assembly,
  config guards, isolation of the command, stopping old jobs, and that the
  plist's defaults match the script's.
- `test/text.test.sh`: `text.pl`, `timeout.pl` and `html_to_text` against
  the fixtures.
- `test/helpers.test.sh`: the assertion helpers in `test/helpers.sh`, run
  in a subshell with fresh counters.
- `test/build.test.sh`, `test/make_release.test.sh`: packaging and release
  guards in temp copies and throwaway git repos. They never write to this
  repo's `dist/` and never reach the network.

Stubs live in `test/stubs.sh`. The variables `SUM_PBPASTE`, `SUM_LSAPPINFO`,
`SUM_OSASCRIPT` and `SUM_CURL` replace those tools with a command line split
on spaces, so the stubs run as `/bin/bash <file>` and need no execute bit.
`textutil` and `perl` run for real in the flow tests. `SUM_COMMAND` points at a stub backend that logs its stdin,
working directory, prompt and model. No test can reach the real `claude`:
the cases that need a command starting with `claude` point `ZDOTDIR` at a
`.zshenv` defining a `claude` function, which zsh runs before searching PATH.

Each failure-path test has a `# breaks-if:` comment naming the change that
would turn it red. Failures here are rendered messages with exit code 0, so
the negative assertions compare the message and check that nothing reached
the backend.

test-failure-paths idioms: "no" "\$\(cmd_ran\)" | refute_contains | refute_file

Nothing automated covers real apps, real permission prompts or Alfred
itself. Check by hand after changing the AppleScript, the Text View or the
plist: the Automation prompt and its denial, the JavaScript setting off,
text streaming into the Text View and ⌘C copying it, a real Mail message,
and a changed keyword.

## Build and release

- `./build.sh` writes `dist/Summarize.alfredworkflow`: `info.plist`,
  `prompt.md`, `scripts/` and `icon.png` if there is one. It sets the
  execute bit on `scripts/*.sh` and `scripts/*.pl` first, because the Text
  View runs `summarize.sh` as a file.
- `bash make_release.sh x.y.z` bumps `info.plist`'s version, builds
  `dist/Summarize-vx.y.z.alfredworkflow` plus a `.sha256`, and prints the
  commit, push and `gh release create` commands. It never commits or
  publishes on its own, and it restores `info.plist` and removes the
  artifacts if any step fails.
