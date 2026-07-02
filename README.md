# Scribe

A hotkey-invoked desktop tool that takes text from your voice or your clipboard,
optionally restyles it with an LLM, and delivers it by typing, pasting, or
leaving it on the clipboard.

Its behaviour is five independent flags, so the command line states exactly what
will happen:

```
--input mic|clipboard            where the text comes from
--window | --no-window           show a review window, or run unattended
--deliver type|paste|clipboard   how the result leaves
--style[=NAME]                   apply a style pass (needs a configured AI provider)
--provider NAME                  pick a [provider.NAME] from config.toml
--quotes double|single|straight  quotation style (default double)
--dialect off|british            British spelling conversion (default off)
```

The style pass is the only feature that needs an API key. With no configuration
and no key, scribe still runs as a dictation tool — the style pass and the styled
review pane are simply absent.

## Dependencies

Runtime commands (must be on `PATH`):

| Command | Provides | Needed for |
|---------|----------|------------|
| `whisper-cli` | speech-to-text (whisper.cpp) | `--input mic` |
| `parecord` | audio capture (PulseAudio / pipewire-pulse) | `--input mic` |
| `dotool` | keystroke injection via uinput | `--deliver type`, and the paste keystroke |

Other requirements:

- **Tcl/Tk 9** with a working `wish9.0` and `tk systray`. The Tcl packages
  `http`, `tls`, `json`, and `yaml` must be available to that interpreter. On
  Ubuntu those were provided by tcllib. With OS X brew they came with tcl9.

- A **whisper model** file (for example `ggml-medium.en.bin`), passed with
  `--model`, for `--input mic`.

- An **AI provider** in `config.toml`, only for `--style` (optional; see below).
- `dotool` needs access to `/dev/uinput` (typically membership of the `input`
  group). For non-ASCII characters (curly quotes, accented names) the `--deliver
  type` path uses IBus Ctrl+Shift+U, so IBus (or fcitx) should be running.

## Setup

1. (Optional, only for `--style`) Copy `config.example.toml` to
   `~/.config/scribe/config.toml` and fill in a provider:

   ```toml
   default_provider = "deepseek"

   [provider.deepseek]
   api_key  = "sk-your-key-here"
   model    = "deepseek-chat"
   api_base = "https://api.deepseek.com"
   ```

   Add more `[provider.NAME]` tables (e.g. `claude`, `chatgpt`) and pick one with
   `--provider NAME` or `default_provider`. Skip this entirely to run dictation
   only. A legacy single-provider `deepseek.json` is still honoured if present.

2. Bind the presets you want to global shortcuts (GNOME custom keyboard
   shortcuts, or your desktop's equivalent).

   A second press of a `--input mic` shortcut stops the recording started by the first.

   For example, to bind dictation to the `Insert` key under GNOME, add a custom
   keybinding whose command is:

   ```
     code/scribe/scribe.tcl --input mic --deliver paste --dialect british \
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
| Dictate straight into the focused window | `scribe.tcl --input mic --no-window --deliver type` |
| Dictate, review, then paste | `scribe.tcl --input mic --window --style --auto-style-delay 1000 --deliver paste` |
| Restyle the clipboard, review, copy back | `scribe.tcl --input clipboard --window --style --auto-style-delay 1 --deliver clipboard` |

`--no-window` requires `--input`. With `--window`, `--input` defaults to `mic`.

## Review window

When a window is shown it has two panes, the source text and the styled text,
with one highlighted. Up and Down (or a mouse click) switch which pane is
highlighted; the buttons act on it. Space delivers, Enter delivers and then
sends a return, and a second button copies to the clipboard without pasting.

## Text normalisation

- `--quotes` rewrites straight quotes: `double` gives “ ” and ’, `single` gives
  ‘ ’ and ’, `straight` leaves ASCII. `--dialect british` makes `single` the
  default unless `--quotes` is given.
- `--dialect british` converts US spelling to British using
  `dialect-us-to-british.tsv` plus `-ize`/`-ise` suffix rules. There is no `us`
  target on purpose; see the comment in `scribe.tcl` for why.

## Configuration files

- `config.toml` (`~/.config/scribe/`): AI providers for the style pass. Optional;
  `[provider.NAME]` tables plus `default_provider`. See `config.example.toml`.
- `styles/*.txt`: style guides, one per file; the name is the `--style` value.
- `current-mode.conf`: the last-used style name, used when `--style` has no name.
- `system-prompts.yaml`: the wrapper text around the style guide and user text.
- `dialect-us-to-british.tsv`: US to British spelling pairs.

## Self-test

```
wish9.0 scribe.tcl --self-test
```

Runs the quote, dialect, injection, delivery, validation, style-pass,
clipboard, and UI checks without a microphone, and exits with the result.
`--test-text "…"` drives the window with fixed text instead of the mic.
