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
--style[=NAME]                   apply a style pass (omit for raw text)
--quotes double|single|straight  quotation style (default double)
--dialect off|british            British spelling conversion (default off)
```

## Dependencies

Runtime commands (must be on `PATH`):

| Command | Provides | Needed for |
|---------|----------|------------|
| `whisper-cli` | speech-to-text (whisper.cpp) | `--input mic` |
| `parecord` | audio capture (PulseAudio / pipewire-pulse) | `--input mic` |
| `dotool` | keystroke injection via uinput | `--deliver type`, and the paste keystroke |
| `wl-copy` / `wl-paste` | Wayland clipboard (wl-clipboard) | `--deliver paste` and `clipboard` |

Other requirements:

- **Tcl/Tk 9** with a working `wish9.0` and `tk systray`. Under GNOME on Wayland
  this needs a Wayland-native Tk build, because the stock X11 Tk cannot draw the
  tray icon or inject focus there. The Tcl packages `http`, `tls`, `json`, and
  `yaml` must be available to that interpreter.
- A **whisper model** file (for example `ggml-medium.en.bin`), passed with
  `--model`, for `--input mic`.
- A **DeepSeek API key** in `deepseek.json`, for `--style`.
- `dotool` needs access to `/dev/uinput` (typically membership of the `input`
  group). For non-ASCII characters (curly quotes, accented names) the `--deliver
  type` path uses IBus Ctrl+Shift+U, so IBus (or fcitx) should be running.

## Setup

1. Put your DeepSeek key in `deepseek.json`:

   ```json
   {
     "api_key": "sk-your-key-here",
     "api_base": "https://api.deepseek.com",
     "model": "deepseek-chat"
   }
   ```

2. Make the script executable: `chmod +x scribe.tcl`.

3. Bind the presets you want to global shortcuts (GNOME custom keyboard
   shortcuts, or your desktop's equivalent), launching `wish9.0 scribe.tcl …`
   with the Wayland-native Tk build. A second press of a `--input mic` shortcut
   stops the recording started by the first.

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
