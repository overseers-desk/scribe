# Experiment: n-Pass Threshold Rewrite

## Problem

When an AI language model is asked to "rewrite this text following rules X, Y, Z," it performs a single holistic pass — holding all rules in working memory simultaneously and editing as it goes. This produces two systematic failure modes:

1. **Insufficient attention.** With multiple rules active at once, the model's attention budget is spread thin. It catches the most obvious violations and misses subtler ones. This is analogous to why lint tools check one rule per rule, not "make the code good."

2. **Insufficient quality control.** The model's editorial judgements are invisible — baked into the output. The user cannot see what was flagged, what was changed, or why. There is no reviewable artefact between "input" and "output," so the user cannot disagree with a diagnosis before the rewrite happens, nor verify that the rewrite actually addressed the diagnosed problem.

These are not hypothetical. In practice, holistic rewrites tend to:
- Fix conspicuous violations while introducing new ones
- Make lateral changes (word A → word B, neither better) that accumulate into voice drift
- Touch sentences that had no problems, cascading unnecessary edits
- Silently drop specific terminology in favour of vague plain English

## Proposed solution: n-pass diagnostic + threshold-gated rewrite

Instead of asking "rewrite to follow these rules," decompose the task:

### Phase 1: Diagnostic (n passes)

Run one pass per rule. In each pass, the model evaluates every sentence against exactly one criterion and produces a binary judgement: 1 (violation) or 0 (clean). This yields an n × S matrix (n rules, S sentences), stored as a CSV.

The single-rule constraint forces the model to attend to one axis at a time, the same way a human copy-editor makes separate passes for grammar, style, and fact-checking rather than trying to catch everything at once.

### Phase 2: Scoring

Merge the n rows into a per-sentence score. Each sentence gets a binary string (e.g. `10101` = broke rules 1, 3, 5) and a count of violations.

### Phase 3: Threshold-gated rewrite

Choose a threshold t. Only rewrite sentences whose score ≥ t. The higher the score, the more urgently the sentence needs work. Sentences below threshold are left untouched — preserving the author's voice, structure, and word choices where they were already adequate.

This gives the user a control knob:
- t=1: rewrite any sentence that breaks any rule (aggressive)
- t=2: rewrite only sentences breaking 2+ rules (moderate)
- t=n: rewrite only sentences breaking all rules (minimal)

### Phase 4: Rule-6 pass (rollback + seam check)

After rewriting, read the complete text through. This pass serves two purposes:
1. **Rollback:** If any rewrite sounds worse than the original (awkward, loses the author's voice, introduces new problems), roll it back.
2. **Seam check:** Where a rewritten sentence sits between untouched sentences, check that the transitions still read smoothly. Edit seams if needed.

This phase is named after Orwell's Rule 6 ("Break any of these rules sooner than say anything outright barbarous") but applies to any rule set: the meta-rule is always "don't make it worse."

## Why Orwell's rules

George Orwell's six rules from "Politics and the English Language" (1946) are used as the rule set for this experiment because:

1. **There are exactly 5 testable rules** (Rule 6 is a meta-rule, not a diagnostic). This maps naturally to a 5-bit binary score per sentence, giving a legible range from 00000 (clean) to 11111 (worst).

2. **The rules are independent axes.** A sentence can break Rule 1 (stale metaphor) without breaking Rule 4 (passive voice), and vice versa. This makes the per-rule passes genuinely separable.

3. **The rules are widely understood** and considered reasonable by most writers. This means the experiment's results are interpretable without specialised knowledge.

4. **The standard is replaceable.** Nothing in the method depends on Orwell specifically. Any set of n independent, binary-testable prose rules could be substituted — house style guides, plain-language standards, accessibility criteria, domain-specific conventions. The method is the contribution; Orwell is the test case.

The 5 diagnostic rules:

| Rule | Short name | Test |
|------|-----------|------|
| R1 | Stale metaphor | Does the sentence use a metaphor, simile, or figure of speech you are used to seeing in print? |
| R2 | Long word | Does the sentence use a long word where a short one will do? |
| R3 | Cuttable word | Does the sentence contain words that can be cut without loss? |
| R4 | Passive voice | Does the sentence use the passive where the active will do? |
| R5 | Jargon | Does the sentence use a foreign phrase, scientific word, or jargon word where an everyday English equivalent exists? |

Rule 6 (break any rule sooner than say anything barbarous) is applied as the rollback/seam-check phase, not as a diagnostic.

## Experiment design

### Input

A 74-sentence founding narrative for opensource.foundation (`sample-original.md`). The text mixes personal memoir, geopolitical history, and technical incident reporting — a good test case because it naturally contains all five violation types.

### Treatments

| ID | Method | Description |
|----|--------|-------------|
| A1 | Holistic rewrite | Single-pass: "rewrite following all 6 Orwell rules." Context-cleared agent — no access to the diagnostic. |
| A2-t1 | n-pass, threshold=1 | Rewrite any sentence breaking ≥1 rule. 42 of 74 sentences rewritten. |
| A2-t2 | n-pass, threshold=2 | Rewrite any sentence breaking ≥2 rules. 26 of 74 sentences rewritten. |

### Controls

- All treatments use the same base model (Claude Opus 4.6).
- A1 agent is context-cleared (no knowledge of the diagnostic matrix).
- A2 variants share the same diagnostic CSV; only the threshold differs.
- All treatments include a Rule 6 (rollback/seam-check) pass.

### Evaluation

A separate context-cleared agent rates each variant (and the original) on six dimensions (clarity, voice, concision, precision, persuasion, Orwell compliance) using a 1–5 star scale. The evaluator has no knowledge of which variant used which method.

## Files in this folder

| File | Description |
|------|-------------|
| `sample-original.md` | Source text (unmodified) |
| `sample-A1-holistic.md` | Treatment A1 output |
| `sample-A2-threshold-1.md` | Treatment A2-t1 output |
| `sample-A2-threshold-2.md` | Treatment A2-t2 output |
| `diagnostic.csv` | 5 × 74 scoring matrix (the shared diagnostic) |
| `01-problem-and-method.md` | This file |
| `02-findings.md` | Results, analysis, and conclusions |
