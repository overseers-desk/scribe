# Scribe — working notes for Claude

The invariants live in [`INVARIANTS.md`](INVARIANTS.md): the no-config promise and the config resolution order. A change that breaks one is a design change, the owner's to make.

@INVARIANTS.md

## The no-config contract

Scribe works as a plain dictation tool when there is **no `config.ini` and no
API key of any kind** (the first invariant). What that means concretely:

- Any input source (typed into the window, dictated via `--input voice` or the
  window's Listen button, or grabbed with `--input clipboard`) → normalisation
  (quotes, dialect) → delivery (type / paste / clipboard) must always work with
  no AI provider and no key. Voice transcription additionally needs a whisper
  model — named in `[whisper] model` or `--model`, with no built-in default —
  and a whisper backend, the same kind of transcription dependency as
  `whisper-cli` on `PATH`; locating the model never pulls in a provider or key.
- The AI **style pass is strictly additive**. It is the only feature that needs a
  provider. When none is configured:
  - never `fatal` / never exit non-zero because config or a key is missing;
  - `loadConfig` leaves `::AI_AVAILABLE` at 0 and resolves nothing;
  - `--style` / `--auto-style-delay` degrade to dictation (with a `notice`), they
    do not error;
  - the review window shows a **single** pane — the rewrite controls, the
    result pane, and the Up/Down pane-switch bindings are not created. The
    Rewrite button stays: clicking it opens a dialog naming `config.ini` and
    pointing at the example, so rewriting reads as unconfigured, not missing
    (`rewrite_or_prompt`).

Concretely: `::AI_AVAILABLE` is the gate for *every provider call* — the
preprocess call and the style call alike; any code that sends text to a
provider must sit behind it. The self-test must pass both with a provider (all
three rewrite dispatches run) and without one (no provider call is made; the
single-pane UI with a config-prompting Rewrite button is asserted).

## Rewrite pipeline

A Rewrite click (or windowless `--style`) runs a pipeline picked by two
independent choices, offered as radio rows in the window and persisted in XDG
state files (`style` and `pipeline`, side by side):

- **Style** — a `styles/NAME.txt` guide, or the reserved name `none` ("No
  style", the default): the clean-up pass alone (repetitions merged,
  self-corrections resolved, points reordered), no style call.
- **Passes** — how a styled rewrite runs. `2` (default): the clean-up call on
  the provider's `model`, then the style call on the repaired text; the result
  pane shows the repaired text until the styled text replaces it, and the
  source pane keeps the raw text. `1`: one merged call (clean-up instructions +
  style guide) to the provider's `thinking_model`, falling back to `model`,
  with a higher token cap since reasoning can eat the completion budget. Moot
  under `none`, so the window greys the row rather than hiding it. Values
  persisted by the former pipeline picker (`2pass`/`1pass`/`style`) load as
  2/1/2 — the style-only call no longer exists; a Rewrite always cleans up.

System prompts live in `system-prompts.yaml`: `preprocess_prefix` (the
clean-up call), `merged_pass_prefix` (1-pass), `single_pass_prefix` (the style
call, 2-pass call 2). All calls share the `user_text_prefix` wrapper and the
`api_call` / `api_response_text` plumbing. Only the terminal callback signals
the self-test and windowless delivery: a stage that signals mid-chain releases
the test's `vwait` and fires delivery after only half the pipeline has run.
Under `none` the clean-up call is itself the terminal stage.

## History

Every delivery, and every Shift+Escape, commits the pair `{original, revised}` to
`history.tsv` beside the `style` and `pipeline` state files. `deliver_now` is the
one funnel for all four delivery modes, so it carries the `history_commit` call;
the two paths reaching the clipboard without it (the Copy button,
`WM_DELETE_WINDOW`) carry their own. Shift+Escape commits with the mark set and
delivers nothing; mid-recording it stops the recording as Escape does, so a
mis-hit cannot take a recording down.

`history_load` runs outside the `::AI_AVAILABLE` gate and the list is built in
both layouts: history needs no provider (first invariant), and the self-test
asserts the pane in both required passes.

An entry is the list `{date mark original revised}`; the history is a list of
those, newest first. `::history_selected` holds the index recalled into the
panes, and committing while it is set updates that entry in place instead of
adding a second copy of a note the delivery has just used. Full at
`::HISTORY_MAX`, `history_trim` drops the oldest unmarked entry and reaches a
marked one only once every entry is marked.

One record per physical line. `history_encode` collapses every line ending
inside a field to a lone CR and `history_decode` expands it back, so the file
reads with `split $data \n`; `csv::join` / `csv::split` (tcllib) take care of
tabs and quotes, which clipboard grabs of spreadsheet cells do carry. Both
channels set `-translation lf`: Tcl's default read translation rewrites a lone
CR to LF, which would turn every stored line break into a record boundary. The
mark stores as `true`/`false` and reads back through `string is true -strict`,
as `unload_after_style` does.

The list is a `tk::listbox`, one row per entry, `date  message`. A treeview
would carry aligned columns for free, but the Wayland Tk this runs on draws its
cells blank; the listbox is a classic Tk widget like the panes, drawing its own
text rather than through the Ttk treeview cell drawing that comes up blank here.
The date leads so its left edge anchors the column in any font, and a
not-yet-used entry's message opens `* `, past the date, where a variable-width
glyph leaves the date alignment untouched. `history_row` trims the message on a
word boundary to `::HISTORY_MSG_CHARS`, and the listbox `-width` is derived from
that same budget so the widest row's ellipsis is not clipped. `-exportselection
0` keeps a row click from seizing the X PRIMARY selection, which would clobber
the user's middle-click paste.

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

- no `server_url` → **local**: `whisper-cli` on the recording (the default
  backend). The model comes from `[whisper] model` or `--model`; local
  transcription with neither reaches `ui_error` (no provider or key needed).
- `server_url` set → **server**: POST the WAV to a whisper.cpp `whisper-server`.
- `+ fallback_local = true` → **server, then local** if the server fails.

CLI overrides win over config (like `--provider`): `--whisper-server URL`,
`--whisper-fallback` / `--no-whisper-fallback`. The `[whisper]` section is read in
`loadConfig` right after `parse_ini`, before the provider-selection returns, so it
applies even with no AI provider.

`transcribe` dispatches to `transcribe_server` (a multipart POST through the
`http` package, async) or `transcribe_local` (the `whisper-cli` path). The
server request has a watchdog that judges it by phase: a connect budget until
the first byte leaves, then the upload's pace projected to the whole body, then
a response budget once the upload is in, since whisper-server sends nothing
while it transcribes. The model checks (unset, then
missing file) live in `transcribe_local`, so server-only mode needs no local
model; fallback still does.
Both backends end at `transcribe_succeeded` → `on_source_ready`. A server failure
(unreachable, too slow by the watchdog, non-200, or an unreadable response) either logs a `notice` and runs
the local backend (fallback on) or reaches `ui_error` (server only); an empty but
valid transcript is not a failure. scribe never starts or supervises the server.

A remote server takes transcription off the local GPU entirely (the other answer
to the VRAM contention `unload_after_style` addresses); a persistent *local*
server instead holds ~2 GB resident and competes with the chat model, so there it
pairs with `unload_after_style` rather than replacing it.
