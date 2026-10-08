# Scribe reference

For installing and a first dictation, see the [README](../README.md). `scribe --help` lists every command-line option, and [`config.example.ini`](../config.example.ini) documents every configuration setting.

## How a run is put together

Each run combines three choices, so the command line states what will happen:

- **Input**, `--input`: `keyboard` (the default) opens an empty window to type into, `voice` records and transcribes, and `clipboard` takes the clipboard's text.
- **Window**, `--window` (the default) or `--no-window`: review the text before it leaves, or deliver it unattended. `--no-window` needs `voice` or `clipboard` input, since there is nothing to type into without a window.
- **Delivery**, `--deliver`: `paste` (the default) pastes into the app that had focus, `type` types it keystroke by keystroke, `clipboard` leaves it on the clipboard, and `stdout` prints it.

Text normalisation and the optional AI rewrite sit between input and delivery.

## Review window

The window holds the dictated text in an editable pane and, down the left, the history list. With an AI provider configured, a second pane holds the rewritten text and one of the two panes is highlighted. Both panes are editable, so you can correct the text before rewriting or delivering.

A **Listen** button in the pane header records from the window itself: press it, dictate, and press it again (or Escape) to stop. The transcript is appended after any text already in the pane. Listen works in windows opened without `--input voice`, and the global shortcut's second press stops it like any other recording.

### Keys

The keys depend on focus. With the window itself focused, as it opens after voice or clipboard input:

- Space delivers.
- Enter delivers and then sends a return.
- Up and Down switch the highlighted pane.

Once you click into a pane to edit, Space and Enter type normally. Deliver with Ctrl+Enter or the button instead. In keyboard mode the window opens with the cursor already in the pane.

Escape closes without pasting and throws the text away. Shift+Escape closes without pasting and keeps the text in history. Closing the window, or the Copy button, copies the text to the clipboard first.

### Rewrite

Two rows of radio buttons between the panes decide what a Rewrite click does. Both choices are remembered between runs, and unattended runs (`--no-window --style`) use them too.

- **Style**: "No style" (the default) runs the clean-up alone. The clean-up repairs what composing in one take leaves behind: repeated versions of a point are merged into the fullest one, self-corrections are resolved, and points are reordered into the sequence the author would have chosen. Picking a style applies its guide on top of the clean-up. A style is a plain-text guide in `styles/NAME.txt`.
- **Passes**, greyed out under "No style": **2 — clean up, then style** (the default) repairs first, then restyles the repaired text. The source pane keeps the raw dictation, and the result pane shows the repaired text until the styled text replaces it. **1 — merged prompt** does both in one call. It works best on a reasoning model: set `thinking_model` in the provider's section, otherwise the call goes to the provider's `model`.

`--auto-style-delay MS` starts the rewrite on its own MS milliseconds after the window opens; `1` starts it at once.

Without an AI provider, the window has the one pane. Rewrite opens a note on how to configure a provider.

## History

Every text scribe delivers is kept. **Shift+Escape** keeps one without delivering it: the window closes, nothing is pasted, and the entry is listed with a `*` to show it has not been used yet. The list runs down the left of the window, newest first, showing the time and the opening words of each entry. Selecting one brings it back into the panes, both the dictation and its rewrite, ready to edit or deliver. Deliver it and the `*` goes.

Entries live in `~/.local/state/scribe/history.tsv` as four tab-separated columns: date, mark, original, rewrite. Line breaks inside an entry are stored as carriage returns, so one entry is always one line and the file opens in anything that reads TSV. When the history is full, the oldest entry without a `*` is dropped first, so text you set aside outlasts ordinary deliveries.

## Text normalisation

- `--quotes` rewrites straight quotes. `double` gives “ ” and ’, `single` gives ‘ ’ and ’, and `straight` leaves ASCII. `--dialect british` makes `single` the default unless `--quotes` is given.
- `--dialect british` converts US spelling to British using `dialect-us-to-british.tsv` plus `-ize`/`-ise` suffix rules. There is no US target. Converting to US spelling is not the mirror image: a blanket `-ise` → `-ize` rule would corrupt words such as praise, cruise and exercise. `off` already leaves whisper's spelling untouched.

## Transcription on a server

By default scribe transcribes locally with `whisper-cli`. To offload transcription to a whisper.cpp `whisper-server`, on this machine or another, add a `[whisper]` section to `config.ini` or pass `--whisper-server URL`:

```ini
[whisper]
model          = /path/to/ggml-medium.en.bin   # local transcription (or pass --model)
server_url     = http://localhost:8080         # or offload to a server
fallback_local = true                          # if it fails, use whisper-cli
```

You run the server yourself; scribe only connects to the URL. With `fallback_local`, keep `model` set (or pass `--model`) so the local path can take over. `--whisper-fallback` and `--no-whisper-fallback` override the setting for one run.

A server request counts as failed when it cannot connect within 5 seconds, when the upload's pace projects past 100 seconds, when no answer comes within 120 seconds of the upload finishing, or when the server returns an error. While the recording uploads, the tray icon's pie fills in orange.

## Files

- `~/.config/scribe/config.ini`: AI providers and the `[whisper]` section, all optional. Scribe looks in `$XDG_CONFIG_HOME/scribe/` first, then `~/.config/scribe/`, then the folder `scribe.tcl` lives in, where a legacy single-provider `deepseek.json` (before 0.6.1) is still read when no `config.ini` is found.
- `~/.local/state/scribe/`: `style` and `pipeline` hold the window's Style and Passes picks, and `history.tsv` the history.
- `styles/*.txt`: style guides, one per file; the file name is the style's name.
- `current-mode.conf`, beside `scribe.tcl`: a default style name for an external mode switcher to write. It applies when the window has no saved pick.
- `system-prompts.yaml`: the instructions sent to the AI provider around the style guide and your text.
- `dialect-us-to-british.tsv`: US to British spelling pairs.
- `/var/local/log/dictation/`: each recording and its transcript, kept if the folder is writable.

## Troubleshooting and testing

Scribe logs to the systemd journal: `journalctl -t scribe`. `--debug` keeps the recording and writes a script that replays the `whisper-cli` call beside it.

To test transcription headlessly, for example over SSH, pair `--deliver stdout` with a virtual display. Scribe is a Tk app, so it needs a display even when no window is shown:

```
xvfb-run -a scribe --input voice --test-file sample.wav --no-window --deliver stdout
```

The self-test runs the quote, dialect, injection, delivery, validation, rewrite, second-press, clipboard, history and window checks without a microphone, and exits with the result. With a provider configured it also runs each rewrite combination.

```
scribe --self-test
```

`--test-text "…"` drives the window with fixed text instead of the microphone.
