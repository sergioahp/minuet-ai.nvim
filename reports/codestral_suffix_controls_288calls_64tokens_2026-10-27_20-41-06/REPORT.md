# Codestral FIM suffix controls benchmark

Run started 2026-10-27 at 20:41 local time. All request timestamps in
`ledger.jsonl` are UTC. This is a follow-up to the [24-call probe](../codestral_suffix_repetition_24calls_64tokens_2026-10-27_20-36-30/REPORT.md),
which observed repeated suffix material but had no control conditions. No
production code or heuristics were changed.

## Design and provenance

The run made 288 actual, successful API requests: eight fixed cursor splits,
four suffix conditions, and nine repeats of every split-condition pair. The
conditions were the original following text, an empty suffix, a single newline,
and a plausible changed following text. A fixed seed (`20261027`) randomized
request order. Each request used `codestral-latest` at the Codestral FIM endpoint,
temperature 0, no stop sequences, nonstreaming, and a 64-token output maximum.
There were no retries, failed calls, or missing usage records. The response
model field remained `codestral-latest`; the alias does not identify a fixed
model snapshot.

Five TeX splits adapt short portions of [Overleaf's public mathematical
expressions example](https://www.overleaf.com/learn/latex/Mathematical_expressions).
Three Lua splits use the repository's `lua/minuet/config.lua` FIM functions as
captured in the earlier probe at commit `f387527`; the same functions remain at
the start commit `3e328f0`. The changed suffixes were written for this benchmark
and are not claimed as source excerpts. `fixtures.json` contains every exact
prefix, suffix, changed suffix, and source label. `manifest.json` records the
schedule and request settings. The [official model page](https://docs.mistral.ai/models/codestral-25-08)
documents FIM support and a 128k context window.

## Cost and record audit

The [official pricing page](https://docs.mistral.ai/inference/pricing), checked
for this run, lists USD 0.30 per million uncached input tokens and USD 0.90 per
million output tokens. Before any call, the harness reserved 2,048 input and
64 output tokens per request at deliberately higher rates of USD 1 and USD 3
per million. The largest request text was far shorter than the 2,048-token
allowance. The complete reservation was USD 0.645120, under the USD 1.50 run
limit and the USD 2 ceiling. No retry could add an unreserved request.

Reported usage summed to 13,887 input and 14,076 output tokens. Applying the
published rates gives **USD 0.0168345 estimated usage cost**. This is calculated
from API usage, not an account invoice; taxes, minimum charges, and other
account terms are outside the measurement. Audit checks found 288 ledger
records, 288 request bodies, 288 response bodies, and 288 distinct scheduled
pairs. The key and authorization header were absent from all saved files.

## Measurements

For each completion, `response_metrics.json` measures its longest contiguous
match with the *original* suffix after collapsing whitespace. The match may
appear anywhere in the completion. The table shows the number with at least
12 or 20 matching characters, plus 95% Wilson intervals for the 12-character
rate. These are text overlap measures, not counts of harmful edits. A completion
may correctly predict a common equation or code fragment without copying the
supplied suffix. Conversely, short copied delimiters fall below both cutoffs.

| Suffix condition | Calls | Match >=12 chars | 95% Wilson interval | Match >=20 chars | Mean output tokens | Hit 64-token limit |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Original | 72 | 31 (43.1%) | 32.3%-54.6% | 17 (23.6%) | 41.6 | 45 |
| Empty | 72 | 32 (44.4%) | 33.5%-55.9% | 22 (30.6%) | 54.8 | 50 |
| Newline | 72 | 30 (41.7%) | 31.0%-53.2% | 21 (29.2%) | 55.5 | 51 |
| Changed | 72 | 19 (26.4%) | 17.6%-37.6% | 19 (26.4%) | 43.7 | 39 |

The paired 12-character risk difference, original minus empty, was -1.4
percentage points across 72 matched fixture-repeat pairs. Original minus
newline was +1.4 points; original minus changed was +16.7 points. Resampling
the eight fixtures as clusters gave respective 95% intervals of -43.1 to
+36.1, -41.7 to +43.1, and -5.6 to +44.4 points. These broad intervals reflect
strong differences between the hand-picked splits. Nine temperature-zero calls
for a fixed split are not nine independent real-world editing situations.
`summary.json` contains both cutoffs, per-fixture counts, Wilson intervals,
paired discordances, and the seeded cluster bootstrap results.

## Manual review of the completions

Exact diagnostic spans clarify what the broad overlap metric counted. Counts
below are ordered original / empty / newline / changed, each out of nine.

| Split | Diagnostic span | Exact matches | Review |
| --- | --- | --- | --- |
| `tex_expression` | The existing equation's right-hand side and close | 9 / 9 / 9 / 9 | The model supplied this natural equation ending under every condition. The original suffix did not cause this span to appear. |
| `tex_operator` | The original operator, equation tail, and close | 9 / 9 / 9 / 0 | With the changed suffix, all nine instead emitted its alternative operator and equation tail. The original tail also appeared without a suffix, so the prefix alone can induce it. |
| `tex_newline` | The complete later display equation | 0 / 0 / 0 / 7 | Seven changed-suffix completions recreated the public example's equation despite its absence from that supplied suffix. The original condition's long matches were mostly the generic phrase `no integer solutions`, not the equation. |
| `lua_expression` | The later `local language` assignment | 0 / 0 / 0 / 0 | Original and changed suffix calls all stopped after `"fim.utils"`; empty and newline calls produced longer alternative code. `fim.utils` is not the module name in the fixture source. |
| `lua_operator` | The full later concatenation | 0 / 0 / 0 / 0 | Original suffix calls returned only a short newline string literal. Empty and newline calls generated the rest of the function. That short literal can be a valid insertion and should not be treated as a deletion target. |
| `lua_newline` | The start of the later class annotation | 7 / 0 / 0 / 0 | The seven original-suffix completions reached an `end` and the beginning of the existing class annotation. It is a partial common annotation, not the complete class name. |

The `tex_operator` changed-suffix span itself occurred 9 / 0 / 0 / 0 in
changed / original / empty / newline order. This is direct evidence that the
following text can steer the generated tail. It does not imply that every
original-suffix overlap was caused by the suffix. `tex_delimiter` stopped at
the missing right-hand side on all nine original calls, with no substantive
suffix copy. `tex_rhs` mainly matched a closing delimiter or common prose;
its apparent overlaps are too weak to diagnose duplication.

The full completions show material differences between conditions that a
single overlap score cannot capture. For example, the original suffix often
shortened Lua completions, whereas the empty and newline controls kept
generating code. Many TeX completions reached the 64-token limit and continued
well past the intended insertion point. A first-line acceptance UI or different
stop settings could have a different user-visible effect.

## Interpretation and limits

This controlled set does not support a blanket claim that providing a suffix
increases repeated text: the overall original and empty/newline overlap rates
were similar, and effects differed sharply by cursor split. It does show that
Codestral sometimes emits text already present after the cursor, sometimes
emits the same text with no suffix, and sometimes follows a changed suffix
closely. A generic substring-stripping rule would also remove ordinary syntax
or a valid minimal insertion in cases such as `lua_operator`.

The fixtures are selected examples, not a random sample of editor completions.
The overlap metric includes commonplace phrases and syntax; it does not judge
whether the full edited document is valid. The 64-token cap truncates many
responses. The `latest` alias and service behavior may change. These results
support inspecting real edit outcomes before changing production heuristics;
this benchmark itself changed none.

## Artifacts

- `*.request.json` and `*.response.json`: complete request and raw response
  bodies for all 288 calls, without authorization headers.
- `ledger.jsonl`: timestamps, status, usage, finish reason, and cumulative cost
  estimate for each attempted request.
- `manifest.json` and `fixtures.json`: schedule, settings, exact inputs, and
  provenance.
- `response_metrics.json` and `response_metrics.csv`: per-call quantitative
  measures; JSON also includes the full completion text for convenient review.
- `summary.json`: group, paired, uncertainty, and exact-anchor statistics.
- `scripts/benchmark_codestral_suffix_controls.py` and
  `scripts/analyze_codestral_suffix_controls.py`: reproducible harness and
  quantitative analysis.
