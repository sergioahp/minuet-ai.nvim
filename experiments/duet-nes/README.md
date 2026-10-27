# duet NES tuning experiments

Exploratory scripts and result logs from tuning the `Minuet duet` NES
(next-edit-suggestion) loop against `openai/gpt-oss-120b` on OpenRouter. This is
iteration/WIP material kept on the `duet-nes` branch for provenance - it is not
production code and is not wired into the plugin or `make test`.

## Running

Most scripts drive the real model and need `OPENROUTER_API_KEY` in the env:

```
OPENROUTER_API_KEY=... nvim --headless -u NONE -i NONE -n \
  -c "luafile experiments/duet-nes/scripts/<name>.lua" -c "qa!"
```

They prepend the dev checkout (`~/code/lua/minuet-ai.nvim`) to the runtimepath
and call into `minuet.duet.*` directly. Some accept env knobs: `BENCH_N`,
`BENCH_STAGES`, `BENCH_PROMPTS`, `BENCH_STRATS`, `MINUET_EFFORT`. Fresh runtime
logs are written to `./tmp/` (gitignored); the files under `logs/` here are
committed snapshots from the runs that drove the decisions below.

Mercury Edit 2 experiments additionally need `INCEPTION_API_KEY`:

```
INCEPTION_API_KEY=... OPENROUTER_API_KEY=... \
  MERCURY_EVAL_STEPS=8 MERCURY_EVAL_REPEATS=3 MERCURY_EVAL_VARIANTS=O,M \
  nvim --headless -u NONE -i NONE -n \
  -c "luafile experiments/duet-nes/scripts/nes_mercury_edit.lua" -c "qa!"
```

## Scripts

| script | what it does |
| --- | --- |
| `nes_repro.lua` | Replays the Typst `x -> y` session step by step, logging request/response/reasoning per step to a JSONL. First exposed the failure modes. |
| `nes_experiment.lua` | Sweep prompt x effort x cursor-marker on the cross-line scenario. |
| `nes_medium.lua` | Confirms `effort=medium` eliminates the reverts seen at `low`. |
| `nes_bench.lua` | apply-success bench running the real read/retry loop: structure (current +/- marker, proposed +/- plan) x prompt (baseline/improved/terse) x stages. |
| `nes_bench2.lua` | Generality: rename vs local finish-at-cursor, improved vs balanced prompt, cursor as a separate note. |
| `nes_sooner.lua` | First-turn responsiveness: shipped vs "eager" prompt at k=1/k=2 (acted vs read vs forward). |
| `verify_prompt.lua` | Sanity check of the shipped config prompt on rename@k=1 and a local edit (no regression). |
| `stab_check.lua`, `stab_check2.lua` | Headless check of the `<S-Tab>` duet+virtualtext toggle (the out-of-phase bug and the synced fix). |
| `inspect_smoke.lua` | Float render/toggle + single-prediction transcript capture. |
| `inspect_session_smoke.lua` | Multi-prediction session history + result tracking (accepted/dismissed/ignored). |
| `nes_mercury_edit.lua` | Corrected-tableau live comparison: OpenRouter chat/tool-call NES (`O`) vs direct Inception Mercury Edit 2 native edit endpoint (`M`). |
| `validate_mercury_context.lua` | Four native Mercury Edit 2 calls comparing the original and bounded prompt builders on project source; checks preview/apply and enforces a 1M-token reservation ceiling. Run from the repository root with `nvim --headless -u NONE -i NONE -n -l experiments/duet-nes/scripts/validate_mercury_context.lua`. |
| `plot_mark_prompt_repro.lua` | Offline Mercury prompt repro for the Typst `plot(..., mark: none)` workflow; writes exact prompt sections and summary flags under `tmp/`. |

## Findings (these drove the commits on this branch)

- `reasoning.effort=low` makes gpt-oss-120b revert the user's own edits; `medium`
  fixes it. (`nes_repro`, `nes_medium`)
- The **prompt is the dominant lever** for apply-patch success, not the message
  structure. The "consolidated big-context diff" idea is a wash for accuracy (a
  KV-cache/cost optimization at best). (`nes_bench`)
- An inline `<|cursor|>` marker is out-of-distribution for an apply_patch-trained
  model: it gets copied into patches and biases reverts. Feeding the cursor as a
  separate note is best (>= none > inline). (`nes_bench` cursor sweep)
- A balanced prompt (finish-at-cursor OR continue a multi-site change) generalises
  without regressing local edits. (`nes_bench2`)
- "Sooner": telling the model to act on a single edit and to skip the redundant
  `read` (the whole file is already provided) takes first-turn action from ~5/8 to
  8/8 with 0 reads and 0 bad patches. (`nes_sooner`, `verify_prompt`)
- Live simplex-tableau use exposed a generic granularity failure: after several
  one-literal edits, the model sometimes inferred a whole row rewrite. The prompt
  now tells NES to match the user's edit granularity (one literal/token in means
  one literal/token out) without adding a table-specific parser.
- Inter-diff prediction memory remains implemented but is default-off. The early
  positive 24-sample read used a misleading pivot and was underpowered; on the
  corrected pivot it did not beat baseline, so it is not part of the production
  default.
- Mercury Edit 2 integration details:
  - Direct Inception `/v1/edit/completions` works and returns a fenced rewritten
    editable region. The plugin now previews/applies that exact region
    replacement directly; the apply_patch path is kept only for deprecated
    chat/tool-call providers.
  - OpenRouter rejected `inception/mercury-edit-2` on `/chat/completions` as an
    invalid model ID in the live probe; `/api/v1/models` currently lists
    `inception/mercury-2` but not `inception/mercury-edit-2`, so the production
    provider uses direct Inception (`INCEPTION_API_KEY`).
  - On the corrected Typst simplex-tableau eval, Mercury Edit was too selective:
    `M` returned no edit for 24/24 predictions (`MERCURY_EVAL_REPEATS=3`,
    `MERCURY_EVAL_STEPS=8`, run `mercury_edit_2026-06-14_05-32-05`). The same
    provider path succeeds on a code-like rename smoke (`b` -> `board`), so this
    is a task/domain mismatch rather than a transport failure. (The tableau needs
    simplex arithmetic the model will not - and arguably should not - guess, so
    it is now kept only as an abstention probe, not the Mercury yardstick.)
  - Format matching: the prompt was brought in line with the documented Next Edit
    format and the cursortab.nvim reference (the closest open-source Mercury API
    client), since matching the training format is the main lever:
    - `recently_viewed_code_snippets` now carries per-item
      `<|recently_viewed_code_snippet|>` blocks: up to 3 cross-file excerpts (~20
      lines) centered on recent cursor positions and read from the latest buffer
      content, plus a `diagnostics` block (nvim LSP) and a `treesitter_context`
      block (enclosing scope / siblings / imports). `staged_git_diff` is emitted
      only for `COMMIT_EDITMSG`, matching cursortab.
    - `code_to_edit` defaults to `[cursor-5, cursor+10]` (Inception's recommended
      window) and snaps out to enclosing treesitter nodes while it fits in
      `max_editable_lines` (default 25). The full file stays outside the tags.
    - `edit_diff_history` is now range-based and matches the reference dialect
      exactly: per-entry `--- /+++` headers, a synthetic `@@ -1,N +1,M @@` (N/M =
      non-empty line counts, no real line numbers, no context lines), then the
      changed block as `-`/`+`. Nearby edits within ~8 lines / ~1s coalesce into
      one entry; the last 5 are kept, processed at send time (idle decay, inverse-
      pair collapse, dedup), most recent last.
    - `"None"` is now treated as Mercury's explicit no-edit signal (in addition to
      an unchanged editable region).
    - New module `lua/minuet/duet/nes_context.lua` (treesitter/diagnostics/git);
      cursor locations are tracked via `session.note_cursor` on BufEnter/CursorHold.
      Knobs live on `provider_options.inception_edit` (`max_editable_lines`,
      `snippet_count`, `snippet_radius`, `max_siblings`, `git_diff_max_bytes`).
