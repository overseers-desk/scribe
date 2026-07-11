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

Concretely: `::AI_AVAILABLE` is the gate for *every provider call* — the
preprocess call and the style call alike; any code that sends text to a
provider must sit behind it. The self-test must pass both with a provider (all
three pipeline modes run) and without one (no provider call is made; the
single-pane UI with a config-prompting Style button is asserted).

## Styling pipeline

A Style click (or windowless `--style`) runs one of three modes, picked in the
styled pane's header and persisted in an XDG state file beside the style pick
(default `2pass`):

- `2pass` — a preprocess call (repetitions merged, self-corrections resolved,
  points reordered) on the provider's `model`, then the style call on the
  repaired text. The styled pane shows the repaired text until the styled text
  replaces it; the source pane keeps the raw text.
- `1pass` — one merged call (preprocess instructions + style guide) to the
  provider's `thinking_model`, falling back to `model`, with a higher token cap
  since reasoning can eat the completion budget.
- `style` — the style call alone.

System prompts live in `system-prompts.yaml`: `preprocess_prefix` (2-pass call
1), `merged_pass_prefix` (1-pass), `single_pass_prefix` (the style call, used
alone in `style` mode and again as 2-pass's second call). All calls share the
`user_text_prefix` wrapper and the `api_call` / `api_response_text` plumbing.
Only the terminal callback signals the self-test and windowless delivery: a
stage that signals mid-chain releases the test's `vwait` and fires delivery
after only half the pipeline has run.

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

## Transcription backend

Speech-to-text runs one of three ways, chosen by a `[whisper]` section in
`config.ini` (independent of `[provider.*]`: transcription, not styling):

- no `[whisper]` / no `server_url` → **local**: `whisper-cli` on the recording
  (the default; the no-config invariant means this needs nothing configured).
- `server_url` set → **server**: POST the WAV to a whisper.cpp `whisper-server`.
- `+ fallback_local = true` → **server, then local** if the server fails.

CLI overrides win over config (like `--provider`): `--whisper-server URL`,
`--whisper-fallback` / `--no-whisper-fallback`. The `[whisper]` section is read in
`loadConfig` right after `parse_ini`, before the provider-selection returns, so it
applies even with no AI provider.

`transcribe` dispatches to `transcribe_server` (POST via `curl`, async, reusing the
local path's non-blocking-pipe + flip-to-blocking-`close` machinery) or
`transcribe_local` (the `whisper-cli` path). The model-exists check lives in
`transcribe_local`, so server-only mode needs no local model; fallback still does.
Both backends end at `transcribe_succeeded` → `on_source_ready`. A server failure
(unreachable, non-200, or an unreadable response) either logs a `notice` and runs
the local backend (fallback on) or reaches `ui_error` (server only); an empty but
valid transcript is not a failure. scribe never starts or supervises the server.

A remote server takes transcription off the local GPU entirely (the other answer
to the VRAM contention `unload_after_style` addresses); a persistent *local*
server instead holds ~2 GB resident and competes with the chat model, so there it
pairs with `unload_after_style` rather than replacing it.
