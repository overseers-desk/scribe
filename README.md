# Scribe

Press a shortcut, speak, press it again, and what you said is typed or pasted into the app you were working in. Transcription runs on your own machine with whisper.cpp, or on a whisper server you run yourself. There is no account to create, and no API key is needed.

Scribe can also take text from the clipboard or from its own window. If you connect an AI provider (DeepSeek, Claude, ChatGPT, a local Ollama model), a Rewrite button tidies dictation that rambles or corrects itself, and can restyle it with a style guide of your choosing. Without a provider, scribe is a plain dictation tool.

Scribe runs on Linux (PipeWire, Wayland or X11) and macOS. The macOS typing and pasting paths have not yet been tested on real hardware.

## Install

```
brew tap overseers-desk/od
brew install scribe
```

This installs the `scribe` command and Tcl/Tk 9. Dictation also needs:

- **whisper.cpp**, for `whisper-cli`: `brew install whisper-cpp`.
- **A whisper model file**, such as `ggml-medium.en.bin` from the [whisper.cpp models](https://huggingface.co/ggerganov/whisper.cpp). Scribe has no default model; you point it at the file.

On Linux, also install from your distribution:

- `pw-record` (PipeWire) to record, or `sox` if you don't use PipeWire.
- `dotool` to type and paste. It writes to `/dev/uinput`, which usually means adding yourself to the `input` group. For the group change, run `sudo usermod -aG input $USER`, then log out and back in.
- `wl-copy` (Wayland) or `xclip` (X11) for the clipboard.
- IBus or fcitx running, if you dictate characters outside ASCII (curly quotes, accented names) with `--deliver type`.

On macOS, Homebrew pulls in `sox`. Typing and the clipboard go through the system's own `osascript` and `pbcopy`. Give the app that launches scribe (your terminal, or the shortcut tool) **Accessibility** and **Microphone** permission under System Settings → Privacy & Security.

From a source checkout (`git clone https://github.com/overseers-desk/scribe`), run `scribe.tcl` with a Tcl/Tk 9 `wish9.0` that has `tk systray`, TclTLS, and tcllib's `json`, `yaml` and `csv`.

## First dictation

```
scribe --input voice --model /path/to/ggml-medium.en.bin
```

Recording starts at once, and the tray icon shows a red pie counting down the time left. Speak, then stop by running the same command again or clicking the tray icon. Recording stops on its own after five minutes (`--timeout` changes this). The transcript opens in a window. Press Space to paste it into the app you were in, or Escape to discard it.

Scribe keeps each recording and its transcript in `/var/local/log/dictation/` when that folder exists and is writable.

To skip the `--model` flag, name the model once in `~/.config/scribe/config.ini`:

```ini
[whisper]
model = /path/to/ggml-medium.en.bin
```

## Put it on a key

Bind the command to a global shortcut in your desktop's keyboard settings. Pressing the shortcut a second time stops the recording. For example, under GNOME, to dictate with the Insert key:

```sh
dir=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
base=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$dir
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$dir']"
gsettings set "$base" name 'Dictate'
gsettings set "$base" binding 'Insert'
gsettings set "$base" command 'scribe --input voice --deliver paste'
```

The command relies on the model named in `config.ini` above; otherwise add `--model`. This snippet replaces any custom shortcuts you already have; if you have some, add the shortcut in Settings → Keyboard instead.

## Common setups

| You want to | Command |
|-------------|---------|
| Dictate straight into the focused app, no window | `scribe --input voice --no-window --deliver type` |
| Dictate, check the text, then paste | `scribe --input voice --deliver paste` |
| Dictate, have it tidied by AI, then paste | `scribe --input voice --style --auto-style-delay 1000 --deliver paste` |
| Restyle the clipboard and copy it back | `scribe --input clipboard --style --auto-style-delay 1 --deliver clipboard` |
| Type into a window, then paste | `scribe` |

`--dialect british` converts US spelling to British; `--quotes` picks curly or straight quotation marks. `scribe --help` lists every option.

## Optional: AI clean-up and styles

Copy `config.example.ini` to `~/.config/scribe/config.ini` and fill in one provider:

```ini
[provider.deepseek]
api_key  = sk-your-key-here
model    = deepseek-chat
api_base = https://api.deepseek.com
```

The window then gains a second pane and a Rewrite button. Rewrite merges repeated points, resolves mid-sentence corrections, and puts points in a sensible order. Pick a style to restyle the result as well. Styles are plain-text guides in the `styles` folder, and you can add your own. `config.example.ini` shows other providers, a local Ollama model, and transcription on a whisper server.

## More

[docs/reference.md](docs/reference.md) covers the review window's keys, history, the configuration files, transcription on a server, and testing.
