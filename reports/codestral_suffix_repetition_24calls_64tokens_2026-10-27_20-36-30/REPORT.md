# Codestral suffix repetition probe

Run: 2026-10-27, timestamps in `ledger.json` (UTC). Repository source: commit
`f387527`, `lua/minuet/config.lua`. Probe: `scripts/probe_codestral_suffix_repetition.py`.
The JSON requests and raw JSON responses in this directory are the full bodies;
no authorization headers were stored. After the run, the script was updated to
include prior usage cost in future preflight output; this did not change requests.
`fixtures.json` records the exact cursor
split, source, and minuet-style language/indentation headers.

## Method and limits

Eight FIM splits, three requests each, with `codestral-latest`, temperature 0,
64 maximum output tokens, nonstreaming, no stops, and no retries. The endpoint
was the Codestral endpoint configured in this repository. The TeX cases adapt
short excerpts from [Overleaf's Mathematical expressions](https://www.overleaf.com/learn/latex/Mathematical_expressions),
with cursor locations chosen for the probe; Lua cases use the repository source
above. The three splits with a newline suffix test code/prose continuation;
other splits test expression tails, operators and delimiters. Every request has
identical settings; repeated temperature-zero responses still varied. These are
hand-picked small contexts, not a representative distribution. There is no
paired empty-suffix control, so this experiment does not establish whether the
suffix caused the repetitions. It measures their occurrence with a suffix.

The [official pricing page](https://docs.mistral.ai/inference/pricing) lists
Codestral at USD 0.30 per million input and USD 0.90 per million output tokens.
The [model page](https://docs.mistral.ai/models/codestral-25-08) lists a 128k
context and FIM support; the [FIM API reference](https://docs.mistral.ai/api/endpoint/fim)
documents prompt, suffix, and the completion endpoint. Pages checked on the run
date. The `latest` alias can change, so the recorded response model matters.

All 24 requests completed. Usage reported 1,341 input and 981 output tokens;
applying published uncached rates gives USD 0.0012852, excluding any account
minimums, taxes or other charges. Before every request the ledger reserved
130,000 input and 64 output tokens at those rates, including for already
completed calls. The last preflight total was USD 0.9373824, below the USD 1.50
reserved budget and USD 2.00 hard ceiling. The reservation exceeds the stated
128k context per request; it is a conservative pricing estimate, not an invoice.
13 responses reached the output limit and 11 stopped. There were no retries.

## Hand review of all 24 responses

Here, a repeated suffix span means a match anywhere in the generated text, not
necessarily at its end. Normalization below removes leading/trailing whitespace
and collapses runs of whitespace to one space; punctuation and letter case stay
unchanged. A suffix can recur later in generated text, in which case trimming a
simple end-of-completion overlap does not address the observed duplication.

| Fixture, requests | Hand-reviewed result | Normalized repeated span |
| --- | --- | --- |
| `tex_expression`, 01-03 | 3/3 generated the missing `y^2` and then repeated the existing equation tail and closing delimiter, before continuing with new prose. | `= z^2\)` |
| `tex_rhs`, 04-06 | 3/3 generated `z^2` and the existing closing delimiter, then continued with new prose. This is a delimiter-only match. | `\)` |
| `tex_operator`, 07-09 | 3/3 repeated the existing operator, expression and closing delimiter immediately at the start, then generated new prose. Initial whitespace differs. | `+ y^n = z^n \]` |
| `tex_delimiter`, 10-12 | 3/3 returned only `z^n` and stopped, leaving the existing closing delimiter intact. | none |
| `tex_newline`, 13-15 | 3/3 wrote an entire display equation that also appears later in the suffix, surrounded by new prose. It is an internal suffix span, not a suffix-prefix overlap. | `\[ x^n + y^n = z^n \]` |
| `lua_expression`, 16-18 | 3/3 stopped after `"fim.utils"`; no substantive suffix match. This module name differs from the repository's `minuet.utils`, so absence of repetition does not imply correctness. | none |
| `lua_operator`, 19-21 | 3/3 returned only `'\n'` and stopped; it also appears later in the suffix as a separate expression. Reuse of a common literal can be correct here and is not evidence of erroneous suffix copying. | `'\n'` |
| `lua_newline`, 22-24 | All emitted `end` before more generated text; 22 continued with the existing class annotation prefix, while 23-24 continued with different annotations. These are common syntax/annotation fragments rather than reliable proof of copying. | 22: `end ---@class minuet.ChatInput`; 23-24: `end` |

Two strong equation-tail cases show duplication in 6/6 responses (01-03 and
07-09). A different complete equation was repeated inside the completion in
3/3 newline cases (13-15). The delimiter-only and common-syntax matches are
reported separately because deleting them on sight could remove valid output.
The suffix is concatenated after the entire completion, so these responses can
duplicate material even when completion-end overlap is absent. In particular,
the long outputs continue past the point where a human would likely stop;
streaming display, first-line acceptance, and different stop settings could
change the impact. These observations alone do not justify a general stripping
heuristic or a frequency estimate for real use.
