# Scribe — working notes for Claude

## Invariant: scribe runs with no configuration and no AI keys

Scribe must work as a plain dictation tool when there is **no `config.ini` and no
API key of any kind**. This is a hard invariant — do not break it.

- Any input source (typed into the window, dictated via `--input voice`, or grabbed
  with `--input clipboard`) → normalisation (quotes, dialect) → delivery (type /
  paste / clipboard) must always work, on its own, with zero configuration.
- The AI **style pass is strictly additive**. It is the only feature that needs a
  provider. When none is configured:
  - never `fatal` / never exit non-zero because config or a key is missing;
  - `loadConfig` leaves `::AI_AVAILABLE` at 0 and resolves nothing;
  - `--style` / `--auto-style-delay` degrade to dictation (with a `notice`), they
    do not error;
  - the review window shows a **single** pane — the styled pane and the Up/Down
    pane-switch bindings are not created. The Style button stays: clicking it
    opens a dialog naming `config.ini` and pointing at the example, so styling
    reads as unconfigured, not missing (`style_or_prompt`).

Concretely: `::AI_AVAILABLE` is the gate for the *style pass itself* — any code
that sends text to a provider must sit behind it. The self-test must pass both
with a provider (style pass runs) and without one (style pass is skipped; the
single-pane UI with a config-prompting Style button is asserted).

## AI provider config

Providers live in `config.ini`, resolved in this order:
`$XDG_CONFIG_HOME/scribe/config.ini` → `~/.config/scribe/config.ini` →
`<app dir>/config.ini` (dev) → legacy `<app dir>/deepseek.json` (pre-0.6.1).

Format is INI (see `config.example.ini`). The config was already valid INI, so
this is a rename for accuracy, not a change of what is parsed; the reader stays a
minimal hand-written one (Tcl ships no TOML or INI parser, and the config never
needed a library):

```ini
default_provider = deepseek

[provider.deepseek]
api_key  = sk-...
model    = deepseek-chat
api_base = https://api.deepseek.com
```

Provider selection: `--provider NAME` (CLI) → `default_provider` → the sole
provider if exactly one is defined → none (dictation only). Any provider whose
section omits `api_key` is treated as not configured.

The INI reader (`parse_ini`) is a deliberately minimal subset — `[section]`
headers and `key = value` lines with optional `"`/`'` quoting and trailing `#`
comments. No value continuation or `;` comments; scribe's config needs none.
Keep it that way unless the config genuinely grows to need more.

A provider may set `unload_after_style = true` (Ollama only): after a successful
style pass scribe drops the model from VRAM through Ollama's native `/api/generate`
(`keep_alive 0`), so whisper has the GPU on the next recording. The style request
itself goes through the OpenAI-compatible endpoint, which ignores `keep_alive`,
hence the separate native call. It is for a single GPU that cannot hold both the
chat model and the whisper model, and costs a cold reload on the next style pass.
