#!/usr/bin/env python3
"""Capture a bounded Codestral FIM suffix-repetition experiment.

Run from the repository root with MISTRAL_API_KEY set. The run creates a new
reports/ directory, records a preflight reservation before each request, and
stops on any error or missing usage. No requests are retried.
"""

import datetime
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.request

ENDPOINT = 'https://codestral.mistral.ai/v1/fim/completions'
MODEL = 'codestral-latest'
MAX_TOKENS = 64
REPEATS = 3
INPUT_RESERVE = 130_000
COST_RESERVE = (INPUT_RESERVE * 0.30 + MAX_TOKENS * 0.90) / 1_000_000
SPEND_LIMIT = 1.50

# Short exact excerpts from the cited source, with cursor positions chosen for
# this experiment. Comment headers match minuet's default FIM template.
TEX_HEADER = '% language: tex\n% indentation: use 2 spaces for a tab\n'
LUA_HEADER = '-- language: lua\n-- indentation: use 4 spaces for a tab\n'
OVERLEAF = 'https://www.overleaf.com/learn/latex/Mathematical_expressions'
REPO = 'lua/minuet/config.lua at f387527'
FIXTURES = [
    {'id': 'tex_expression', 'source': OVERLEAF,
     'prefix': TEX_HEADER + 'The well known Pythagorean theorem \\(x^2 + ',
     'suffix': ' = z^2\\) was\nproved to be invalid for other exponents.\n'},
    {'id': 'tex_rhs', 'source': OVERLEAF,
     'prefix': TEX_HEADER + 'The well known Pythagorean theorem \\(x^2 + y^2 = ',
     'suffix': '\\) was\nproved to be invalid for other exponents.\n'},
    {'id': 'tex_operator', 'source': OVERLEAF,
     'prefix': TEX_HEADER + 'Meaning the next equation has no integer solutions:\n\n\\[ x^n ',
     'suffix': ' + y^n = z^n \\]\n\n\\end{document}\n'},
    {'id': 'tex_delimiter', 'source': OVERLEAF,
     'prefix': TEX_HEADER + 'Meaning the next equation has no integer solutions:\n\n\\[ x^n + y^n = ',
     'suffix': ' \\]\n\n\\end{document}\n'},
    {'id': 'tex_newline', 'source': OVERLEAF,
     'prefix': TEX_HEADER + 'The well known Pythagorean theorem \\(x^2 + y^2 = z^2\\) was\n',
     'suffix': '\nMeaning the next equation has no integer solutions:\n\n\\[ x^n + y^n = z^n \\]\n'},
    {'id': 'lua_expression', 'source': REPO,
     'prefix': LUA_HEADER + 'local default_fim_prompt = function(context_before_cursor, _, _)\n    local utils = require ',
     'suffix': "\n    local language = utils.add_language_comment()\n    local tab = utils.add_tab_comment()\n"},
    {'id': 'lua_operator', 'source': REPO,
     'prefix': LUA_HEADER + 'local default_fim_prompt = function(context_before_cursor, _, _)\n    local utils = require \'minuet.utils\'\n    local language = utils.add_language_comment()\n    local tab = utils.add_tab_comment()\n    context_before_cursor = language .. ',
     'suffix': " .. tab .. '\\n' .. context_before_cursor\n\n    return context_before_cursor\nend\n"},
    {'id': 'lua_newline', 'source': REPO,
     'prefix': LUA_HEADER + 'local default_fim_suffix = function(_, context_after_cursor, _)\n',
     'suffix': '\nend\n\n---@class minuet.ChatInputExtraInfo\n'},
]


def timestamp() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds')


def main() -> None:
    key = os.environ.get('MISTRAL_API_KEY')
    if not key:
        raise SystemExit('MISTRAL_API_KEY is unavailable')
    name = datetime.datetime.now().strftime('codestral_suffix_repetition_24calls_64tokens_%Y-%m-%d_%H-%M-%S')
    output = Path('reports') / name
    output.mkdir(parents=True, exist_ok=False)
    (output / 'fixtures.json').write_text(json.dumps(FIXTURES, indent=2) + '\n')
    ledger = []
    reserve_total = 0.0
    input_total = output_total = 0
    count = 0
    for fixture in FIXTURES:
        for repetition in range(1, REPEATS + 1):
            projected = reserve_total + COST_RESERVE
            if projected > SPEND_LIMIT:
                raise SystemExit('Preflight spend ceiling reached')
            count += 1
            body = {'model': MODEL, 'prompt': fixture['prefix'], 'suffix': fixture['suffix'],
                    'max_tokens': MAX_TOKENS, 'temperature': 0, 'stream': False}
            stem = f'{count:02d}_{fixture["id"]}_rep{repetition}'
            (output / f'{stem}.request.json').write_text(json.dumps(body, indent=2) + '\n')
            reserve_total = projected
            entry = {'request': count, 'fixture': fixture['id'], 'repetition': repetition,
                     'preflight_timestamp_utc': timestamp(), 'prior_reported_input_tokens': input_total,
                     'prior_reported_output_tokens': output_total,
                     'prior_usage_cost_usd': (input_total * 0.30 + output_total * 0.90) / 1_000_000,
                     'request_input_reserve_tokens': INPUT_RESERVE,
                     'request_output_reserve_tokens': MAX_TOKENS, 'cumulative_reserved_usd': reserve_total,
                     'status': 'reserved'}
            ledger.append(entry)
            (output / 'ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
            print(f'Preflight {count}/24: reported tokens {input_total} in, {output_total} out; '
                  f'prior usage USD {(input_total * 0.30 + output_total * 0.90) / 1_000_000:.6f}; '
                  f'reserved {count * INPUT_RESERVE} in, {count * MAX_TOKENS} out; '
                  f'cumulative USD {reserve_total:.6f}', flush=True)
            request = urllib.request.Request(ENDPOINT, data=json.dumps(body).encode(), method='POST',
                    headers={'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'})
            start = time.monotonic()
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    raw, status = response.read(), response.status
            except urllib.error.HTTPError as exc:
                raw, status = exc.read(), exc.code
            except (OSError, TimeoutError) as exc:
                entry.update(status='transport_error', error=type(exc).__name__, completed_timestamp_utc=timestamp())
                (output / 'ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
                raise SystemExit('Transport error; request may have been billed, stopping') from None
            # Authorization is never included in the payload or stored headers.
            (output / f'{stem}.response.json').write_bytes(raw)
            entry.update(status=status, completed_timestamp_utc=timestamp(), elapsed_seconds=round(time.monotonic()-start, 3))
            try:
                response_body = json.loads(raw)
                usage = response_body['usage']
                input_total += usage['prompt_tokens']
                output_total += usage['completion_tokens']
                entry['usage'] = usage
                entry['finish_reason'] = response_body['choices'][0].get('finish_reason')
            except (ValueError, KeyError, IndexError, TypeError):
                (output / 'ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
                raise SystemExit(f'HTTP {status} or missing usage; stopping without retry') from None
            (output / 'ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
            if status != 200:
                raise SystemExit(f'HTTP {status}; stopping without retry')
    print(f'Complete: {count} requests, {input_total} input and {output_total} output tokens; '
          f'conservative reservation USD {reserve_total:.6f}; results in {output}', flush=True)


if __name__ == '__main__':
    main()
