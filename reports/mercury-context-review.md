# Mercury oversized-context review

Reviewed on 2026-10-27 against baseline `79d0315`.

Select approach B, `fix/mercury-prompt-budget` at `5e1fa0c`, for landing on
main. It prevents oversized generated prompts before transport and covers all
sources of context while preserving the original editable region. No blocking
defect was found in this approach. The choice follows independent inspection
and validation, rather than accepting the implementation authors' conclusions.

## Candidates and deliberation

| Approach | Reviewed commits | Decision |
| --- | --- | --- |
| A: current-file byte window | Implementation `547188c`, final branch tip `2ba9200` | Do not land: limits only non-editable current-file text. |
| B: complete generated prompt budget | Implementation `a45ad54`, tests/final tip `5e1fa0c` | Land: predictable upper bound across all prompt sections. |
| C: adaptive context-error retry | Implementation `f902683`, tests/final tip `734772a` | Do not land: recovery requires a rejected full request and recognized error payload. |

Approach A is the smallest change. It shares unused space between the two sides
of the editable region and avoids splitting UTF-8 characters. However, its
32000-byte setting excludes the editable region, diagnostics, cross-file
snippets, syntax context, edit history, and tags. Large supplementary content
can therefore reproduce the same failure. Byte cuts can also leave partial
non-editable source lines. These are substantive limits of the design, not
test failures. They remain unresolved in this candidate.

Approach B accounts for the complete generated tagged prompt: tags, file path,
cursor marker, editable text, local context, history, and supplementary blocks.
It reserves the mandatory portion first, then allocates up to a quarter of the
remaining space each to history and supplementary snippets. Unused space goes
to nearby current-file lines. History remains a chronological suffix of whole
entries; supplementary blocks remain whole; file context remains a contiguous
excerpt of whole lines. A giant adjacent line stops expansion on that side
instead of breaking UTF-8 or silently joining unrelated source text.

The editable region's absolute rows and original lines remain independent of
the cropped context. The chat adapter still returns a direct region replacement,
so repeated text elsewhere in a large buffer cannot redirect the edit. If the
mandatory content exceeds the budget, the adapter invokes the normal error
callback before creating a request. The error names the requested cap and
suggests a smaller editable window or larger cap. Tested nonpositive,
fractional, infinite, and string-valued caps are rejected. Existing provider
transport and response handling remain structurally unchanged.

Approach C preserves full context when the first request succeeds. Its bounded
fallback uses the same buffer snapshot and original absolute region, retries
at most once, and correctly avoids retries for explicit authentication,
rate-limit, and server errors. The final mock tests exercise preview and apply
after recovery. Nevertheless, every oversized prediction first sends the entire
large prompt, adding a rejected network round trip and bandwidth before usable
work. Recovery depends on recognized JSON context errors and drops all
supplementary snippets/history. If the editable region cannot fit the fallback,
the original oversized request is still attempted and its rejection ends the
request. These tradeoffs make it less suitable than B for the reported failure.

## Observed prompt sizes

The shared measurement harness uses 1100 synthetic lines, each 101 source
characters, with cursor positions at rows 1, 550, and 1100. Stress cases add a
200000-byte source line, large diagnostics, or ten large edit-history entries.
The harness passes each branch's configured Mercury options to its builder.
Numbers below are UTF-8 prompt bytes, excluding the JSON envelope.

| Case | Baseline | A | B | C first request | C fallback |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cursor at row 550 | 112441 | 33873 | 31963 | 112441 | 23905 |
| Cursor at row 1 | 112441 | 33363 | 31963 | 112441 | 23905 |
| Cursor at row 1100 | 112441 | 32853 | 31963 | 112441 | 23905 |
| Large diagnostics | 452544 | 373976 | 31963 | 452544 | 23905 |
| Large edit history | 512931 | 414464 | 31963 | 512931 | 23905 |
| Giant non-editable line | 312340 | 33873 | 31963 | 312340 | 23905 |
| Giant editable line | 312340 | 233772 | Local rejection | 312340 | Unavailable |

For B's last case, mandatory prompt content needs 201772 bytes; the default cap
is 32000. Preserving that region and rejecting locally is safer than silently
truncating editable source or sending a request known to violate the configured
bound.

The harness and JSON observations are retained under the ignored
`tmp/mercury-context/` workspace. They are synthetic reproductions, not evidence
of the live model's context window or completion quality.

## Independent validation

- Inspected all implementation diffs, configuration, README additions, session
  context/history assembly, chat error handling, and final regression tests.
- Independently ran the complete test suite in A: 185 tests passed.
- Independently ran the complete test suite in B at its final implementation
  and test state: 188 tests passed.
- Independently ran C's full suite while its final tests were being completed:
  187 tests passed. Then reran all seven final retry specs at `734772a`, including
  the added oversized-supplementary-context preview/apply case; all passed. The
  author additionally reports the final complete suite of 188 passing tests.
- Ran 2000 deterministic randomized B builder checks with varying line counts,
  cursor positions, editable windows, Unicode, caps, diagnostics, syntax text,
  and history. All passed: 1751 accepted prompts stayed within their caps and
  reconstructed the exact contiguous source excerpt and original editable
  region; 249 oversized mandatory regions returned actionable local errors.
  The scratch harness is `tmp/mercury-context/reviewer-budget-check.lua`.
- Verified B's committed subprocess regression applies only original row 550
  among duplicate lines at rows 1, 550, and 1100.

No live API request was exercised and no production credentials were used.
Changed-file formatting checks are reported passing by the authors. After this
review selected B, the parent merged it into main using merge commit `04f9a2a`
and reports 189 passing tests, changed-file StyLua checks, and a clean diff
whitespace check. The extra test comes from a preexisting user modification;
the parent reports both preexisting modified files remained byte-for-byte
unchanged.

## Accepted limits and follow-up

B's cap counts bytes, not model tokens, output tokens, or JSON encoding overhead.
It is a configurable conservative bound, not an exact guarantee for every
model/tokenizer. The README explicitly documents this. The default 32000 bytes
is suitable for this deterministic reduction but has not been calibrated with
the user's failing live payload.

Whole-block selection can omit a large useful diagnostic or history entry even
when smaller portions would be informative. Static quarter allocations can
also leave capacity unused when local file context is short. These are quality
tradeoffs; they do not violate the cap or editable-region integrity. Optional
context is assembled before selection, so this change bounds network prompt
size rather than all local temporary memory allocation.

The existing `provider_options.inception_edit.optional.messages` escape hatch
can explicitly override the generated messages after the builder runs. The
budget governs the generated tagged prompt, not arbitrary user-supplied
replacement messages. Restricting that preexisting override is outside this
fix and is not required to address normal large-buffer requests.

Recommend landing B alone, preserving A and C as alternative branches and
worktrees. Do not combine retry complexity with the proactive fix without live
evidence that the bounded default still needs recovery.
