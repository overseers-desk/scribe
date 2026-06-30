# Scribe — working notes for Claude

## Invariant: scribe runs with no configuration and no AI keys

Scribe must work as a plain dictation tool when there is **no `config.toml` and no
API key of any kind**. This is a hard invariant — do not break it.

- Dictation/clipboard → normalisation (quotes, dialect) → delivery (type / paste /
  clipboard) must always work, on its own, with zero configuration.
- The AI **style pass is strictly additive**. It is the only feature that needs a
  provider. When none is configured:
  - never `fatal` / never exit non-zero because config or a key is missing;
  - `loadConfig` leaves `::AI_AVAILABLE` at 0 and resolves nothing;
  - `--style` / `--auto-style-delay` degrade to dictation (with a `notice`), they
    do not error;
  - the review window shows a **single** pane — the styled pane, the Style button,
    and the Up/Down pane-switch bindings are not created.

Concretely: `::AI_AVAILABLE` is the gate. Any code that assumes a provider exists
must sit behind it. The self-test must pass both with a provider (style pass runs)
and without one (style pass is skipped, dictation-only UI is asserted).

## AI provider config

Providers live in `config.toml`, resolved in this order:
`$XDG_CONFIG_HOME/scribe/config.toml` → `~/.config/scribe/config.toml` →
`<app dir>/config.toml` (dev) → legacy `<app dir>/deepseek.json` (pre-0.6.1).

Format (TOML, matching the other Overseers Desk tools — see `config.example.toml`):

```toml
default_provider = "deepseek"

[provider.deepseek]
api_key  = "sk-..."
model    = "deepseek-chat"
api_base = "https://api.deepseek.com"
```

Provider selection: `--provider NAME` (CLI) → `default_provider` → the sole
provider if exactly one is defined → none (dictation only). Any provider whose
section omits `api_key` is treated as not configured.

The TOML reader (`parse_toml`) is a deliberately minimal subset — `[section]`
headers and `key = value` lines with optional `"`/`'` quoting and trailing `#`
comments. No arrays, inline tables, or multiline strings; scribe's config needs
none. Keep it that way unless the config genuinely grows to need more.
