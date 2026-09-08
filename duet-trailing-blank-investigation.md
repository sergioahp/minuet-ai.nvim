# Duet: the blank line Mercury "removes" at the end of a suggestion

Symptom, as reported: `Minuet duet` suggestions with the Inception Mercury Edit
provider are usually right, but the last hunk of a change often deletes one
blank line that nobody asked to remove.

Conclusion: the model is not doing this. Our own response parser is. It was
eating exactly one trailing blank line off every fenced Mercury response.

## Reproduction

`scripts/probe_inception_trailing_blank.lua` (untracked, `scripts/` is
gitignored) drives the real shipped path -- `session.build_inception_edit_turn`
-> `chat.request` -> `split_region` -- against `api.inceptionlabs.ai`, on two
scenarios whose editable region ends in a blank line and whose edit history
motivates a real edit (user changed `scale(p1, 2)` -> `scale(p1, 3)`; the good
next edit propagates that to `p2`/`p3`):

- `propagate_mid`: 38-line file, region `[1,16]` snapped by treesitter, ending
  on the blank separator between two functions.
- `propagate_eof`: 6-line file whose last line is blank.

Each sample is scored twice: `model` is a faithful parse of the response (fence
body kept with its final newline, then exactly one line terminator stripped --
the same one-newline-per-line convention `build_inception_edit_turn` ships),
`shipped` is whatever `split_region` returned.

Before the fix, K=8 per scenario:

```
propagate_mid  model kept=8 dropped=0 | shipped kept=0 dropped=8 | fenced=8
propagate_eof  model kept=8 dropped=0 | shipped kept=0 dropped=8 | fenced=8
```

16/16 responses carried the region's trailing blank line faithfully. 16/16
shipped replacements had it removed. A raw response looks like this:

```
"```\nlocal M = {}\n...\nend\n\n```"
```

The blank line before the closing fence is the region's last line.

## Cause

`strip_markdown_fence` matched `^%s*```[^\n]*\n(.-)\n```%s*$`, so the capture
already dropped the newline that terminates the body's last line. `split_region`
then stripped a second trailing newline, which for a region ending in a blank
line was that line itself. So a 16-line region came back as 15 lines and the
preview showed the real edit plus a spurious blank-line deletion at the region
tail.

Commit 72ff205 ("Handle Mercury EOF blank no-op") had already hit this from the
other side: it only saw the case where the elision was the *whole* diff, at EOF,
and suppressed those as no-ops. Mid-file, or riding along with a genuine edit,
the deletion still shipped.

## Fix

`lua/minuet/duet/chat.lua`:

1. The fence pattern keeps the body's final newline
   (`^%s*```[^\n]*\n(.-)```%s*$`), and `split_region` strips exactly one line
   terminator. A blank last line now survives, and the `<|cursor|>` marker is
   removed before the strip so the marker sitting alone on that blank line still
   parses as a blank line.
2. `restore_elided_trailing_blanks` guards the case where the model itself
   elides the tail: if the replacement has fewer trailing blank lines than the
   region, the missing ones are appended back. The region tail is a cursor
   window boundary, not a syntactic unit, so deleting it is never the edit the
   user wants. This subsumes the EOF-only `is_same_region_or_eof_blank_elided`
   special case -- once the blanks are restored, the plain identity check
   collapses a blanks-only "edit" to a no-op, at EOF or anywhere else.

After the fix, same probe, K=8 per scenario:

```
propagate_mid  model kept=8 dropped=0 | shipped kept=8 dropped=0
propagate_eof  model kept=8 dropped=0 | shipped kept=8 dropped=0
```

Covered by `tests/duet_transport_spec.lua`:

- "keeps a trailing blank line the model returned" -- the parse fix, mid-file.
- "restores a trailing blank the model elided mid-file" -- the guard.
- "treats an omitted trailing cursor blank as no edit" -- the pre-existing EOF
  case, now handled by the general guard.

## Not addressed

The symmetric case, a model that *adds* trailing blank lines beyond the region's
own, is left alone: it was never observed in the probes, and clamping it would
also clip a legitimate edit that ends by opening a new line.
