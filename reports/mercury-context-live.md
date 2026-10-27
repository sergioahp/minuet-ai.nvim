# Mercury Edit 2 live context validation

Run: 2026-10-27 07:50:47 UTC. Native endpoint:
`https://api.inceptionlabs.ai/v1/edit/completions`, model `mercury-edit-2`.

The bounded prompt fixes a reproduced live context-size rejection. The rejected
full prompt was 161412 bytes; the bounded prompt for the same editing task was
31999 bytes and produced exactly the expected edit through the plugin's real
request, response parsing, preview, and apply path.

## Material and method

The source was the repository's actual `lua/minuet/duet/init.lua`: 1075 lines,
40176 bytes, at revision `fdab8a8`. In an in-memory buffer, the experiment renamed
one local declaration from `memory_entry` to `shown_memory`, recorded that edit
in the session history, and asked Mercury to predict the next edit. The expected
change was the corresponding value in `memory_entry = shown_memory`, six lines
below the declaration. No source file on disk was changed.

The ordinary case used that file once. A context stress case concatenated four
copies into a 4300-line in-memory fixture, with the rename in the third copy.
This expanded fixture is source-derived test material, not an independently
executable Lua module. It deliberately contains repeated copies of the target
text, making correct placement of the replacement observable.

The full-prompt cases loaded the original session builder from commit `79d0315`.
The bounded cases used the builder on main with its default 32000-byte cap.
Both used `duet.action.predict()` followed by `duet.action.apply()` when a preview
was available, the native curl transport, and `max_tokens = 1000`. There were no
mock API responses and no automatic retries.

## Observed results

| Fixture | Prompt | Bytes | Input tokens | Output tokens | Result |
| --- | --- | ---: | ---: | ---: | --- |
| Original 1075 lines | Full | 40884 | 9072 | 142 | Exact expected rename applied |
| Original 1075 lines | Bounded | 31999 | 7018 | 140 | Exact expected rename applied |
| Expanded 4300 lines | Full | 161412 | Not reported | Not reported | `context_length_exceeded`; buffer unchanged |
| Expanded 4300 lines | Bounded | 31999 | 6933 | 138 | Exact expected rename applied |

All three successful responses ended with `finish_reason = stop`. Every apply
matched the expected entire buffer, including preservation of every line outside
the editable region. In the expanded bounded case, the edited use was original
buffer row 2678, inside editable rows 2667-2682. Other copies stayed unchanged.
Observed request-to-completion durations ranged from 828 to 1062 milliseconds;
four observations are insufficient for a latency benchmark.

The original 1075-line file did not trigger the failure. The expanded fixture
did. These results demonstrate a real rejection and successful bounded recovery,
but do not reproduce the user's particular file or establish a line-count limit.

The API error contained `type = invalid_request_error`, `param = messages`, and
`code = context_length_exceeded`. Its message named a maximum context length of
128000. The current [official model table](https://docs.inceptionlabs.ai/get-started/models)
lists a 32K NextEdit context window for Mercury Edit 2. This run does not resolve
that discrepancy; the accepted/rejected payloads and the byte cap are recorded
without inferring an exact tokenizer threshold from the error text.

## Budget and evidence

Four requests were sent. The three successful responses reported 23443 total
tokens. The rejection reported no usage. Before each request, the harness
reserved twice the encoded request byte count, plus the output-token limit and
4096 tokens for overhead. Reservations were retained even for rejected calls.
The total conservative reservation was 567978 tokens, below the user's hard
1000000-token limit. The harness also kept the earlier USD 0.50 ceiling.

At the documented uncached input price of USD 0.25 per million tokens and output
price of USD 0.75 per million, successful reported usage corresponds to
USD 0.00607075 before cache discounts or trial credits. This is a list-price
estimate, not an account billing measurement. Trial-token balance and any
unreported rejected-request usage were not queried.

[Committed evidence](mercury-context-live_mercury-edit-2_cap-32000_2026-10-27_07-50-47.json)
includes case measurements, exact API responses, request hashes, the source hash,
and budget reservations. Full requests, inspect records, and applied in-memory
fixture snapshots remain in the ignored run directory:
`tmp/mercury-context/mercury-edit-2_cap-32000_2026-10-27_07-50-47/`.
Authentication headers and keys are not stored in these artifacts.

Reproduce from the repository root with `INCEPTION_API_KEY` already set:

```sh
nvim --headless -u NONE -i NONE -n -l experiments/duet-nes/scripts/validate_mercury_context.lua
```

The harness creates a fresh timestamped directory and performs four live calls.
No further API calls were needed after the failure and fix were both observed.
