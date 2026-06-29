# Findings

## Diagnostic summary

The 5-pass diagnostic scored 74 sentences against Orwell's 5 testable rules. Distribution of per-sentence violation counts:

| Score | Meaning | Count | % of total |
|-------|---------|-------|------------|
| 0 | Clean — no rules broken | 32 | 43% |
| 1 | One rule broken | 16 | 22% |
| 2 | Two rules broken | 11 | 15% |
| 3 | Three rules broken | 11 | 15% |
| 4 | Four rules broken | 4 | 5% |
| 5 | All rules broken | 0 | 0% |

The original text is already fairly clean: 43% of sentences pass all five rules. The worst offenders (score 4) are sentences 8, 40, 54, and 62 — all dense, policy-heavy or technically-heavy sentences that stack jargon, passive voice, long words, and padding simultaneously.

Rule violation frequency across the corpus:

| Rule | Violations | % of sentences |
|------|-----------|----------------|
| R1 — Stale metaphor | 14 | 19% |
| R2 — Long word | 18 | 24% |
| R3 — Cuttable word | 22 | 30% |
| R4 — Passive voice | 13 | 18% |
| R5 — Jargon | 17 | 23% |

R3 (cuttable words) is the most common violation — the text has a tendency toward appositional padding and verbal throat-clearing. R4 (passive voice) is the least common, suggesting the author already writes in a naturally active register.

## Evaluation results

A context-cleared evaluator rated each variant on six dimensions (1–5 stars):

| Dimension | Original | A1 (holistic) | A2-t1 (t=1) | A2-t2 (t=2) |
|-----------|----------|---------------|-------------|-------------|
| Clarity | 4.5 | 4.5 | 4.0 | 4.5 |
| Voice | 4.5 | 4.0 | 3.5 | 4.5 |
| Concision | 3.5 | 4.0 | 4.0 | 4.0 |
| Precision | 4.5 | 4.5 | 4.0 | 4.5 |
| Persuasion | 4.5 | 4.0 | 3.5 | 4.5 |
| Orwell | 3.5 | 4.5 | 4.0 | 4.0 |
| **Overall** | **4.0** | **4.0** | **3.5** | **4.5** |

Final ranking:

| Rank | Variant | Stars |
|------|---------|-------|
| 1 | A2-t2 (n-pass, threshold=2) | 4.5 |
| 2 | Original (no edit) | 4.0 |
| 3 | A1 (holistic rewrite) | 4.0 |
| 4 | A2-t1 (n-pass, threshold=1) | 3.5 |

## Analysis

### Finding 1: The structured method (A2) outperforms holistic rewriting (A1) — but only at the right threshold

A2-t2 (threshold=2) is the highest-rated variant. A2-t1 (threshold=1) is the lowest. The method itself is not the differentiator — the threshold is. This confirms the hypothesis that **targeted editing outperforms blanket editing**, but also shows that a structured method with a bad threshold can be worse than no method at all.

### Finding 2: Holistic rewriting is a wash

A1 scored the same overall (4.0) as the unedited original. It gained half a star on Orwell compliance and concision, but lost half a star on voice and persuasion. The evaluator described it as "a very good editor" rather than "a person thinking aloud." The systematic word-swapping — "drinking" for "having," "struck" for "removed," "answered" for "responded" — produced uniform prose that is technically cleaner but less alive.

This is the core problem the n-pass method was designed to solve: **a holistic rewrite does not know when to stop.** It edits sentences that were already working because it has no mechanism to distinguish "this sentence breaks a rule" from "this sentence is fine."

### Finding 3: Threshold=1 over-edits and damages structure

A2-t1 rewrote 42 of 74 sentences (57%). The evaluator noted three specific damages:

1. **Paragraph collapse.** The aggressive rewriting merged several paragraph breaks in the geopolitical section into a dense wall of text. The structure of the original — which used paragraph breaks as rhetorical pacing — was lost.

2. **Terminology loss.** "Entity List" was replaced with "restricted-trade list." "Foreign Direct Product Rule" was dropped by name. These are specific legal instruments; replacing them with generic descriptions loses precision that the text's audience (policy and tech professionals) needs.

3. **Voice flattening.** The evaluator rated A2-t1's voice at 3.5 — a full star below the original. The most-edited variant sounded the least like a person.

The lesson: **threshold=1 is too aggressive for text that is already competently written.** When 43% of sentences are clean, rewriting 57% means touching many sentences that only break one rule — and that single violation is often a judgement call (e.g., is "cool down" really a stale metaphor, or is it just colloquial?).

### Finding 4: Threshold=2 preserves what works and fixes what doesn't

A2-t2 rewrote 26 of 74 sentences (35%). It left the 32 clean sentences and 16 single-violation sentences untouched. The result:

- **Voice preserved.** Rated 4.5, matching the original. The author's cadence, word choices, and personal asides survived because they were mostly in clean or low-score sentences.
- **Precision preserved.** Kept "Entity List," "Foreign Direct Product Rule," "OFAC," "NDAA" — all specific terms that matter to the audience.
- **Concision improved.** The 26 rewritten sentences were tighter: "no technical safeguard could reduce the risk" instead of "no combination of technical controls could sufficiently mitigate the risks."
- **Strongest closing line.** "The very pressures open source set out to overcome should not be the ones that break its promise" — rated by the evaluator as the most rhetorically effective ending of all four variants.

### Finding 5: The diagnostic CSV is valuable independent of the rewrite

Even if no rewriting were performed, the diagnostic matrix is a useful artefact:

- It tells the author which sentences need attention and why.
- It reveals patterns (e.g., R3 is the most common violation — the author tends to pad).
- It makes editorial judgements transparent and reviewable before any changes are made.
- The per-sentence score creates a natural priority order: fix score-4 sentences first.

This separates diagnosis from treatment — a distinction that the holistic approach collapses entirely.

### Finding 6: The method generalises beyond Orwell

Nothing in the pipeline depends on Orwell's specific rules. The same structure works for any set of n independent, binary-testable criteria:

- **Plain language standards** (e.g., Federal Plain Language Guidelines): n passes for sentence length, word complexity, nominalisation, hedging, etc.
- **House style guides:** n passes for brand voice markers.
- **Accessibility criteria:** n passes for reading level, sentence structure, terminology.
- **Technical writing standards:** n passes for precision, ambiguity, imperative mood, etc.

The contribution is the pipeline (diagnose per-rule → score → threshold → rewrite → rollback), not the rule set.

## Known limitations

1. **Diagnostic subjectivity.** Rule 1 (stale metaphor) is more subjective than Rule 4 (passive voice). The CSV looks precise, but some cells are judgement calls. A human review of the diagnostic before rewriting would improve reliability.

2. **Single evaluator.** The evaluation was performed by one AI agent. Human evaluation, or multiple independent AI evaluators, would strengthen the findings.

3. **Single input text.** The experiment used one 74-sentence text. The optimal threshold likely varies by input quality — a poorly written text might benefit from threshold=1; a polished text might need threshold=3.

4. **Tense error survival.** All three treatments (and the evaluator) noted a tense slip in sentence 16 ("none of them are sure" in a past-tense narrative). Only A1 fixed it — because it rewrote holistically. A2-t2 left it untouched because the sentence only scored 1 (R3 only). This suggests that **some errors are not captured by style rules** and need a separate correctness pass.

5. **Repetition blindness.** The phrase "infrastructure the world depends on" appears three times in A2-t2. The per-sentence diagnostic cannot detect cross-sentence repetition — it only sees one sentence at a time. A corpus-level pass for repeated phrases would complement the per-sentence diagnostic.

## Conclusions

1. **Structured, rule-separated editing outperforms holistic rewriting** when the threshold is set correctly. The key insight is that separating diagnosis from treatment — and making the diagnosis visible and reviewable — prevents over-editing.

2. **The optimal threshold depends on input quality.** For competently written text (43% clean sentences), threshold=2 was optimal. Threshold=1 over-edited. The right default for production use is likely t=2, with t=1 reserved for rough drafts and t=3+ for polished text.

3. **The diagnostic artefact has standalone value.** Even without rewriting, the CSV tells the author what to fix and where. This makes the method useful as a review tool, not just an editing tool.

4. **The method is rule-set agnostic.** Orwell's rules are a good default for general prose, but the pipeline works with any binary-testable criteria. The 5-rule / 5-bit structure is a convenient coincidence, not a requirement.

5. **Holistic rewriting is unreliable.** It cannot distinguish "needs editing" from "is fine," so it edits everything, producing uniform prose that is technically cleaner but less distinctive. For text with a strong authorial voice, this is a net loss.
