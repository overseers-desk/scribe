# Invariants

Rules whose breach is a design change, not a fix; changing one is the owner's decision.

- Scribe works as a plain dictation tool with no `config.ini` and no API key of any kind: dictation out of the box is the product's promise, so the AI style pass is strictly additive and a missing provider degrades to dictation with a notice, not an error or a non-zero exit. Every provider call sits behind the `::AI_AVAILABLE` gate; the degrade behaviour and the self-test's two required passes are elaborated in CLAUDE.md §The no-config contract.
- `config.ini` resolves in exactly this order: `$XDG_CONFIG_HOME/scribe/` → `~/.config/scribe/` → the app directory (development) → legacy `deepseek.json` (pre-0.6.1). New lookup locations do not get added: each one widens where a credential-bearing file may silently load from, and a config found in a surprising place is a debugging trap.
