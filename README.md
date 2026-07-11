# Scribe

A hotkey-invoked desktop tool that takes text you type, dictate, or hold on the
clipboard, optionally restyles it with an LLM, and delivers it by typing,
pasting, or leaving it on the clipboard.

Its behaviour is five independent flags, so the command line states exactly what
will happen:

```
--input keyboard|voice|clipboard where the text comes from (default keyboard)
--window | --no-window           show a review window, or run unattended
--deliver type|paste|clipboard|stdout  how the result leaves (stdout prints it)
--style[=NAME]                   apply a style pass (needs a configured AI provider)
--provider NAME                  pick a [provider.NAME] from config.ini
--quotes double|single|straight  quotation style (default double)
--dialect off|british            British spelling conversion (default off)
```

The style pass is the only feature that needs an API key. With no configuration
and no key, scribe still runs as a dictation tool — the style pass and the styled
review pane are simply absent.

## Install

Homebrew (Linux and macOS):

```
brew tap overseers-desk/od
brew install scribe
```

On macOS the formula pulls `sox` for audio capture; keystrokes and clipboard go
through the system's own `osascript` and `pbcopy`. On Linux the formula installs
scribe and Tcl/Tk only. For `--input voice`, install whisper.cpp separately
(`brew install whisper-cpp` provides `whisper-cli`) and supply a whisper model
file such as `ggml-medium.en.bin`. On Linux, a recorder (`pw-record`, or `sox`
as fallback) and `dotool` must also be on `PATH` (see Dependencies below).

## Dependencies

Runtime commands (must be on `PATH`):

| Command | Provides | Needed for |
|---------|----------|------------|
| `whisper-cli` | speech-to-text (whisper.cpp) | `--input voice`, local transcription |
| `curl` | POST audio to a whisper.cpp server | `--input voice` with a `[whisper]` server |
| `pw-record` | audio capture (PipeWire; preferred on Linux) | `--input voice` |
| `sox` | audio capture (macOS via coreaudio; Linux fallback when pw-record is absent) | `--input voice` |
| `dotool` | keystroke injection via uinput (Linux) | `--deliver type`, and the paste keystroke |

On macOS, keystrokes go through `osascript` (System Events) and the clipboard
through `pbcopy`/`pbpaste`, both of which ship with the OS. Grant the app that
launches scribe (e.g. your terminal) **Accessibility** permission for
typing/pasting and **Microphone** permission for recording, under System
Settings → Privacy & Security.

Other requirements:

- **Tcl/Tk 9** with a working `wish9.0` and `tk systray`. The Tcl packages
  `http`, `tls`, `json`, and `yaml` must be available to that interpreter. On
  Ubuntu those were provided by tcllib. With OS X brew they came with tcl9.

- A **whisper model** file (for example `ggml-medium.en.bin`), passed with
  `--model`, for `--input voice`.

- An **AI provider** in `config.ini`, only for `--style` (optional; see below).
- `dotool` needs access to `/dev/uinput` (typically membership of the `input`
  group). For non-ASCII characters (curly quotes, accented names) the `--deliver
  type` path uses IBus Ctrl+Shift+U, so IBus (or fcitx) should be running.

## Setup

1. (Optional, only for `--style`) Copy `config.example.ini` to
   `~/.config/scribe/config.ini` and fill in a provider:

   ```ini
   default_provider = deepseek

   [provider.deepseek]
   api_key  = sk-your-key-here
   model    = deepseek-chat
   api_base = https://api.deepseek.com
   ```

   Add more `[provider.NAME]` sections (e.g. `claude`, `chatgpt`, a local Ollama
   model) and pick one with
   `--provider NAME` or `default_provider`. Skip this entirely to run dictation
   only. A legacy single-provider `deepseek.json` is still honoured if present.

2. Bind the presets you want to global shortcuts (GNOME custom keyboard
   shortcuts, or your desktop's equivalent).

   A second press of a `--input voice` shortcut stops the recording started by the first.

   For example, to bind dictation to the `Insert` key under GNOME, add a custom
   keybinding whose command is:

   ```
     code/scribe/scribe.tcl --input voice --deliver paste --dialect british \
     --timeout 300 --window --model code/whisper.cpp/models/ggml-medium.en.bin \
     --prompt-file ~/.whisper-prompt-file
   ```

   ```sh
   dir=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
   base=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$dir
   gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$dir']"
   gsettings set "$base" name 'Insert Voice Message'
   gsettings set "$base" binding 'Insert'
   gsettings set "$base" command '[the above launch command]'
   ```

## Presets

| Goal | Command |
|------|---------|
| Dictate straight into the focused window | `scribe.tcl --input voice --no-window --deliver type` |
| Dictate, review, then paste | `scribe.tcl --input voice --window --style --auto-style-delay 1000 --deliver paste` |
| Restyle the clipboard, review, copy back | `scribe.tcl --input clipboard --window --style --auto-style-delay 1 --deliver clipboard` |

With no `--input`, scribe defaults to `keyboard`: it opens an empty window for you
to type into. `--no-window` needs `--input voice` or `--input clipboard`, since
there is nothing to type into without a window.

## Review window

When a window is shown it has two panes, the dictated text and the result,
with one highlighted. The rewrite controls and the result pane appear only
when a provider is configured. Both panes are editable: click into one to
correct the text before rewriting or delivering.

Between the panes, two rows of radios pick what a Rewrite click does. Both
choices are remembered between runs, and unattended (`--no-window --style`)
runs use them too.

- **Style**: "No style" (the default) runs the clean-up alone; picking a style
  applies its guide on top of the clean-up. The clean-up repairs what
  composing in one take leaves behind: repeated versions of a point merged
  into the fullest one, mid-stream self-corrections resolved, and points
  reordered into the sequence the author would have chosen (a prerequisite
  recalled late moves ahead of what depends on it).
- **Passes** (greyed under "No style", where it is moot): **2 — clean up,
  then style** (the default) repairs first, then restyles the repaired text;
  the source pane keeps the raw dictation, and the result pane shows the
  repaired text until the styled text replaces it. **1 — merged prompt** does
  both in one call. Best on a reasoning model: set `thinking_model` in the
  provider's config section, otherwise the call goes to the provider's
  regular `model`.

The keys depend on focus. With the window itself focused (as it opens after voice
or clipboard input), Space delivers, Enter delivers and then sends a return, and
Up/Down switch the highlighted pane. Once you click into a pane to edit, Space and
Enter type normally; deliver with Ctrl+Enter or the button. Escape closes without
pasting; closing the window (or the Copy button) copies to the clipboard first.
In keyboard mode the window opens with the cursor already in the pane, ready to
type.

## Text normalisation

- `--quotes` rewrites straight quotes: `double` gives “ ” and ’, `single` gives
  ‘ ’ and ’, `straight` leaves ASCII. `--dialect british` makes `single` the
  default unless `--quotes` is given.
- `--dialect british` converts US spelling to British using
  `dialect-us-to-british.tsv` plus `-ize`/`-ise` suffix rules. There is no `us`
  target on purpose; see the comment in `scribe.tcl` for why.

## Configuration files

- `config.ini` (`~/.config/scribe/`): AI providers for the style pass, and an
  optional `[whisper]` transcription backend. Optional; `[provider.NAME]` sections
  plus `default_provider`, and `[whisper]` `server_url`/`fallback_local`. See
  `config.example.ini`.
- `styles/*.txt`: style guides, one per file; the name is the `--style` value.
- `current-mode.conf`: the last-used style name, used when `--style` has no name.
- `system-prompts.yaml`: the wrapper text around the style guide and user text.
- `dialect-us-to-british.tsv`: US to British spelling pairs.

## Transcription backends

By default scribe transcribes locally with `whisper-cli`. To offload transcription
to a whisper.cpp `whisper-server` (on this or another machine), add a `[whisper]`
section to `config.ini`, or pass `--whisper-server URL`:

```ini
[whisper]
server_url = http://localhost:8080   # use the server
fallback_local = true                # if it is down, use whisper-cli
```

You run the server yourself (scribe only reaches the URL); server mode needs
`curl`. With `fallback_local`, keep a valid `--model` so the local path can take
over. Omit `[whisper]` to transcribe locally as before.

To test the loop headlessly (e.g. over SSH, where there is no display), pair
`--deliver stdout` with a virtual display: `xvfb-run -a scribe.tcl --input voice
--test-file sample.wav --no-window --deliver stdout` prints the transcript instead
of typing or pasting it. scribe is a Tk app, so it still needs a display; `xvfb-run`
supplies a throwaway one.

## Self-test

```
wish9.0 scribe.tcl --self-test
```

Runs the quote, dialect, injection, delivery, validation, styling-pipeline
(all three modes, when a provider is configured), clipboard, and UI checks
without a microphone, and exits with the result.
`--test-text "…"` drives the window with fixed text instead of the mic.
