# Summarize, an Alfred workflow

Summarize what you are looking at, or what you copied, into a one-line TL;DR
and a few bullet points. Type `sum`, pick a row, and the summary appears in an
Alfred Text View. Press ⌘C to copy it.

By default the summary comes from Claude through the `claude` command line
tool. Any other command that reads text on stdin and prints a summary on
stdout works too.

## Requirements

- Alfred 5.5 or later with the Powerpack. Alfred 5.5 added the Text View.
- macOS. The workflow was developed and tested on macOS 26.7 with Safari
  27.0 and is untested on older versions. Older Safari releases may put the
  menu items named under "Permissions and settings" elsewhere. The workflow
  uses `pbpaste`, `lsappinfo`, `osascript`, `curl`, `textutil` and the system
  Perl, which all ship with macOS. Nothing from Homebrew is needed.
- A logged-in `claude` (run `claude` once in a terminal), or another command
  set under "Command" in the Configure Workflow screen. The default command
  was tested with `claude` 2.1.326. An older `claude` may reject one of its
  options.

## Install

### From a release

1. Download `Summarize-v<version>.alfredworkflow` and the matching
   `.sha256` file from the latest release on
   [GitHub Releases](https://github.com/iwan-uschka/alfred-workflow-summarize/releases),
   into the same directory.
2. In that directory, check the download. For example, for 0.1.0:

   ```
   shasum -a 256 -c Summarize-v0.1.0.alfredworkflow.sha256
   ```

   It prints `Summarize-v0.1.0.alfredworkflow: OK`. Any other output means
   the file is damaged or not the released one. Do not import it.
3. Double-click the `.alfredworkflow` file to import it into Alfred.

### From source

1. Run `./build.sh`. It writes `dist/Summarize.alfredworkflow`.
2. Double-click that file to import it into Alfred.

## Usage

Type `sum` and pick one of two rows. They always appear in this order:

| Row | What it sends | Subtitle |
| --- | --- | --- |
| Active window | The selected text in the frontmost browser tab, or the whole page text with its title and URL when nothing is selected. In Mail, the selected message's subject, sender and body. | The app and what it reads, for example `Safari: selection or page text`, `Mail: selected message`, `Notes: not supported`. |
| Clipboard | The clipboard text. If the clipboard holds one URL and nothing else, the workflow downloads that page and sends its text. | The first 60 characters of the clipboard, the URL's host, or `empty`. |

Typing after the keyword narrows the rows: `sum cl` shows only Clipboard,
`sum win` only Active window.

The clipboard counts as a URL only when, after trimming, it is a single
`http://` or `https://` link with a host, at most 2048 characters long. A link
followed by more text, a longer link, a bare `example.com/page`, or a lone
`http://` is sent as text.

The summary is a `TL;DR:` line followed by 3 to 10 bullets, fewer for short
input and more for long or dense input. It is in the input's language unless
you set one.

## Supported apps

| App | Active window reads |
| --- | --- |
| Safari | The selection, else the page text plus title and URL |
| Google Chrome | The selection, else the page text plus title and URL |
| Brave Browser | The selection, else the page text plus title and URL |
| Mail | The one selected message: subject, sender and body |
| Firefox | Nothing. Shows "Not supported in Firefox." |
| Any other app | Nothing. Shows `Not supported in <app>.` |

Firefox offers no AppleScript access to its pages, and other apps have no
common way to read their content, so the list is fixed. For a page in any
other browser, copy its URL and use the Clipboard row.

## Configuration

Open the workflow in Alfred and click "Configure Workflow".

| Setting | Variable | Default | Meaning |
| --- | --- | --- | --- |
| Keyword | `SUM_KEYWORD` | `sum` | The keyword that shows the two rows. |
| Command | `SUM_COMMAND` | `claude -p --model "$SUM_MODEL" --tools "" --strict-mcp-config --no-session-persistence --system-prompt "$SUM_PROMPT"` | The backend. See below. |
| Model | `SUM_MODEL` | `sonnet` | Handed to the command as `$SUM_MODEL`. |
| Language | `SUM_LANGUAGE` | empty | Language of the summary. Empty means the language of the input. |
| Fewest bullets | `SUM_MIN_BULLETS` | `3` | Lower end of the bullet range, at most 100. |
| Most bullets | `SUM_MAX_BULLETS` | `10` | Upper end of the bullet range, at most 100. |
| Prompt override | `SUM_PROMPT_OVERRIDE` | empty | Replaces the bundled `prompt.md` when not empty. |

The prompt is `prompt.md` inside the workflow. You can edit it there, or put
your own text into "Prompt override". In both, `{min_bullets}`,
`{max_bullets}` and `{language}` are replaced with the settings above.

### The command

The workflow runs the Command setting with `/bin/zsh -c` in a new, empty
temporary directory, which it deletes afterwards. The text to summarize goes
to the command's stdin. Whatever the command prints on stdout is the summary.
The command gets two environment variables:

- `SUM_MODEL`: the Model setting.
- `SUM_PROMPT`: the finished prompt.

If the command exits with a non-zero code, the Text View shows its stderr.
The default command turns off Claude Code's built-in tools with `--tools ""`.
With `--strict-mcp-config` it ignores every MCP server configuration, because
it passes no `--mcp-config`. `--no-session-persistence` keeps it from saving a
session. Plugins and hooks from your Claude Code settings still load.

Output appears in the Text View as the command prints it. `claude -p` with
its default text output prints the whole summary at once when it is done, so
with the default command you see "Summarizing…" until the summary appears.
The Text View never shows a Markdown image or an HTML tag from the output.
The workflow turns an image into "[image: alt text]", keeps only the text
of a link and removes HTML tags, so text from a page cannot make Alfred load a
remote image.

### Advanced

These variables are not on the Configure Workflow screen. Change them in the
workflow's Environment Variables (the `[x]` button in Alfred's workflow
editor).

| Variable | Default | Meaning |
| --- | --- | --- |
| `SUM_MAX_CHARS` | `200000` | Longer input is cut to this many characters, and the Text View says so above the summary. At most 10000000. |
| `SUM_TIMEOUT` | `120` | Seconds the command may run. At most 100000000. |
| `SUM_FETCH_TIMEOUT` | `15` | Seconds for downloading a page from a clipboard URL, and again for converting it to text. At most 100000000. |
| `SUM_APP_TIMEOUT` | `60` | Seconds an app may take to answer AppleScript, and the limit for reading the clipboard. The first AppleScript call waits for the macOS permission prompt, so keep this generous. At most 100000000. |

## Messages

When something goes wrong, the Text View shows one of these instead of a
summary:

| Message | Cause |
| --- | --- |
| `Nothing to summarize.` | Empty clipboard, no window, an empty selection on an empty page, or no or an empty Mail message. |
| `Not supported in <app>.` | The frontmost app is not in the table above. Nothing was sent. |
| `Select one message in Mail. More than one is selected.` | Several messages are selected. Nothing was sent. |
| `The command failed with exit code <n>.` | The command's stderr follows. If the command starts with `claude`, the hint "Run `claude` once in a terminal to log in, or update `claude` if it rejected an option." follows too. |
| `The command timed out after <n> s (SUM_TIMEOUT).` | The command ran too long and was stopped. |
| `The command returned no summary.` | The command succeeded but printed nothing. |
| `Could not fetch <host>: <curl error>.` | No connection, an unknown host, a TLS problem. |
| `Fetching <host> timed out after <n> s (SUM_FETCH_TIMEOUT).` | The page took too long. |
| `<host> answered with HTTP <code>.` | The page returned an error, for example 403 or 404. |
| `Could not convert the page at <host> to text.` | textutil failed on the downloaded page. |
| `Converting the page at <host> timed out after <n> s (SUM_FETCH_TIMEOUT).` | textutil took too long on the downloaded page. |
| `The page at <host> has too little text to summarize (<n> characters).` | Under 200 characters of text, typical for login walls and pages built by JavaScript. |
| `<host> sent <type>, not a web page.` | The URL points to something other than HTML, XHTML or a `text/*` type, for example a PDF, an image or JSON. |
| `<app> does not allow JavaScript from Apple Events.` | Turn on the setting named in the message (see below). |
| `Alfred may not control <app>.` | macOS denied the Automation permission (see below). |
| `<app> did not answer within <n> s (SUM_APP_TIMEOUT).` | The app hung or a permission prompt waited too long. |
| `Could not read <app>: <error>` | Any other AppleScript error, for example a browser window without tabs. |
| `Could not read the clipboard: <error>` | pbpaste failed. |
| `The clipboard did not answer within <n> s (SUM_APP_TIMEOUT).` | pbpaste hung. |
| `Could not read prompt.md.` | The bundled prompt file is missing or unreadable. Restore it or set "Prompt override". |
| `Could not prepare the input for the command.` | The text helper failed while cutting the input. |
| `Summarize stopped unexpectedly (exit code <n>).` | The job crashed. Its last stderr lines follow. |
| `Summarize stopped unexpectedly.` | The job was killed, or it could not start. Its last stderr lines follow. A backend that was running at that moment may keep running. |
| `This summary is gone. Run it again from the keyword.` | The Text View asked for a job that no longer exists. |
| `Pick the "Active window" or "Clipboard" row to summarize.` | Text typed into the Text View, or an unknown argument. |
| `<VARIABLE> must be a whole number of 1 or more (got "<value>").` | A bullet count, `SUM_MAX_CHARS` or a timeout is not a positive whole number. |
| `<VARIABLE> must be <max> or less (got "<value>").` | A bullet count is above 100, `SUM_MAX_CHARS` above 10000000, or a timeout above 100000000. |
| `SUM_MIN_BULLETS (<a>) is larger than SUM_MAX_BULLETS (<b>).` | The bullet range is upside down. |
| `SUM_COMMAND is empty. Set it in the workflow's Configure Workflow screen.` | The Command setting is blank. |
| `Input cut to <n> characters (SUM_MAX_CHARS).` | Shown above the summary when the input was longer than the limit. |

The fetch messages (download error, timeout, HTTP error, conversion error,
too little text, not a web page) end with "Open the page in your browser and use the
"Active window" row." The browser often gets a page that a plain download
does not, for example behind a login.

## Permissions and settings

The first time Active window reads an app, macOS asks whether Alfred may
control it. Click OK. If you clicked "Don't Allow", turn it on under System
Settings > Privacy & Security > Automation > Alfred.

Browsers block page access from AppleScript until you allow it once:

- Chrome and Brave: View > Developer > Allow JavaScript from Apple Events.
- Safari: Develop > Developer Settings > Allow JavaScript from Apple Events.
  Turn on the Develop menu first under Safari > Settings > Advanced.

The setting covers the whole browser. Once it is on, any app with Automation
permission for that browser can run JavaScript in every tab.

Mail needs no extra setting.

## Privacy

Everything the workflow reads goes to the configured command: page text,
selections, clipboard contents and full mail bodies with sender and subject.
With the default command, that is Claude Code, which sends it to Anthropic.
If you set another command, it goes wherever that command sends it. When the
clipboard holds a URL, the workflow also downloads that page itself with
`curl`, so the site sees your IP address and the URL. Nothing is sent while
the rows are shown. Sending starts only when you press Enter on
a row, and the "not supported" and "Nothing to summarize." cases send
nothing.

The workflow keeps the text it read in a job directory under Alfred's
workflow cache, readable only by your user. It deletes the text as soon
as it has handed it to the command, or when the job fails before reaching
the command. A job that is killed outright, or cut off by a restart, leaves
the text there until an open Text View shows the failure or, if the view is
closed, until the next run starts. The summary or failure message
stays there until the Text View shows it, or, if you closed the view
mid-run, until the next run starts.

## Checks that need a person

The test suite stubs every app, the clipboard, the network and the backend.
These parts only show up in real use, so check them by hand after changing
them:

- The macOS Automation prompt for Safari, Chrome, Brave and Mail, and the
  message after denying it.
- The "Allow JavaScript from Apple Events" message with the setting off.
- Text appearing in the Text View while a streaming command prints it, and
  ⌘C copying the summary.
- A real Mail message, including one with an empty body.
- The keyword change in Configure Workflow taking effect.

## Development

See [AGENTS.md](AGENTS.md).

## License

MIT, see [LICENSE](LICENSE).
