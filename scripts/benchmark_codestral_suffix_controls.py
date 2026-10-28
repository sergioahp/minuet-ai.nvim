#!/usr/bin/env python3
"""Run a bounded, paired Codestral FIM suffix benchmark without retries.

Run from the repository root with MISTRAL_API_KEY set. Each scheduled request
is attempted once. Raw request and response bodies are saved without headers.
"""

import datetime
import json
import os
from pathlib import Path
import random
import time
import urllib.error
import urllib.request

from probe_codestral_suffix_repetition import FIXTURES


ENDPOINT = 'https://codestral.mistral.ai/v1/fim/completions'
MODEL = 'codestral-latest'
MAX_TOKENS = 64
REPEATS = 9
SEED = 20261027
INPUT_RESERVE = 2048
OUTPUT_RESERVE = MAX_TOKENS
INPUT_RATE = 0.30
OUTPUT_RATE = 0.90
RESERVATION_INPUT_RATE = 1.00
RESERVATION_OUTPUT_RATE = 3.00
SPEND_LIMIT = 1.50
WAIT_SECONDS = 0.35

CHANGED_SUFFIXES = {
    'tex_expression': ' = w^2\\) remains an illustrative equation.\n',
    'tex_rhs': '\\) appears in the next sentence about a different identity.\n',
    'tex_operator': ' - y^n = w^n \\]\n\n\\end{document}\n',
    'tex_delimiter': ' + k \\]\n\n\\end{document}\n',
    'tex_newline': '\nThe following section discusses a different example.\n\n\\[ a + b = c \\]\n',
    'lua_expression': '\n    local mode = utils.get_mode()\n    local enabled = mode ~= nil\n',
    'lua_operator': " .. language .. '\\n' .. context_before_cursor\n\n    return context_before_cursor\nend\n",
    'lua_newline': '\nend\n\n---@class minuet.AlternativeInputInfo\n',
}


def timestamp() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds')


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=True) + '\n')


def main() -> None:
    key = os.environ.get('MISTRAL_API_KEY')
    if not key:
        raise SystemExit('MISTRAL_API_KEY is unavailable')

    fixtures = [dict(fixture, changed_suffix=CHANGED_SUFFIXES[fixture['id']]) for fixture in FIXTURES]
    conditions = ('original', 'empty', 'newline', 'changed')
    schedule = [
        {'fixture': fixture['id'], 'repetition': repetition, 'condition': condition}
        for repetition in range(1, REPEATS + 1)
        for fixture in fixtures
        for condition in conditions
    ]
    random.Random(SEED).shuffle(schedule)
    assert len(schedule) == 288
    assert max(
        max(len(fixture['prefix'].encode()) + len(fixture['suffix'].encode()),
            len(fixture['prefix'].encode()) + len(fixture['changed_suffix'].encode()))
        for fixture in fixtures
    ) < INPUT_RESERVE - 256
    reservation = len(schedule) * (INPUT_RESERVE * RESERVATION_INPUT_RATE
                                   + OUTPUT_RESERVE * RESERVATION_OUTPUT_RATE) / 1_000_000
    if reservation > SPEND_LIMIT:
        raise SystemExit(f'Preflight reservation USD {reservation:.6f} exceeds limit')

    name = datetime.datetime.now().strftime('codestral_suffix_controls_288calls_64tokens_%Y-%m-%d_%H-%M-%S')
    output = Path('reports') / name
    output.mkdir(parents=True, exist_ok=False)
    write_json(output / 'fixtures.json', fixtures)
    write_json(output / 'manifest.json', {
        'created_utc': timestamp(), 'endpoint': ENDPOINT, 'model': MODEL,
        'maximum_output_tokens': MAX_TOKENS, 'repeats': REPEATS, 'seed': SEED,
        'conditions': conditions, 'schedule': schedule, 'no_retry': True,
        'input_reserve_tokens_per_request': INPUT_RESERVE,
        'output_reserve_tokens_per_request': OUTPUT_RESERVE,
        'published_input_usd_per_million': INPUT_RATE,
        'published_output_usd_per_million': OUTPUT_RATE,
        'reservation_input_usd_per_million': RESERVATION_INPUT_RATE,
        'reservation_output_usd_per_million': RESERVATION_OUTPUT_RATE,
        'preflight_reservation_usd': reservation,
        'spend_limit_usd': SPEND_LIMIT,
        'pricing_url': 'https://docs.mistral.ai/inference/pricing',
    })
    fixture_by_id = {fixture['id']: fixture for fixture in fixtures}
    ledger_path = output / 'ledger.jsonl'
    input_total = output_total = completed = 0
    print(f'Preflight: {len(schedule)} attempts, USD {reservation:.6f} reserved; {output}', flush=True)
    with ledger_path.open('a') as ledger:
        for index, item in enumerate(schedule, 1):
            fixture = fixture_by_id[item['fixture']]
            condition = item['condition']
            suffix = {
                'original': fixture['suffix'], 'empty': '', 'newline': '\n',
                'changed': fixture['changed_suffix'],
            }[condition]
            body = {'model': MODEL, 'prompt': fixture['prefix'], 'suffix': suffix,
                    'max_tokens': MAX_TOKENS, 'temperature': 0, 'stream': False}
            stem = f'{index:03d}_{item["fixture"]}_{condition}_rep{item["repetition"]}'
            write_json(output / f'{stem}.request.json', body)
            record = dict(item, request=index, stem=stem, started_utc=timestamp(), status='started')
            request = urllib.request.Request(
                ENDPOINT, data=json.dumps(body).encode(), method='POST',
                headers={'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'},
            )
            start = time.monotonic()
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    raw, status = response.read(), response.status
            except urllib.error.HTTPError as exc:
                raw, status = exc.read(), exc.code
            except (OSError, TimeoutError) as exc:
                record.update(status='transport_error', error=type(exc).__name__,
                              finished_utc=timestamp(), elapsed_seconds=round(time.monotonic()-start, 3))
                ledger.write(json.dumps(record) + '\n')
                ledger.flush()
                print(f'Transport error at {index}; request may have been billed; stopping', flush=True)
                break
            (output / f'{stem}.response.json').write_bytes(raw)
            record.update(status=status, finished_utc=timestamp(),
                          elapsed_seconds=round(time.monotonic()-start, 3))
            try:
                response_body = json.loads(raw)
                usage = response_body['usage']
                input_total += usage['prompt_tokens']
                output_total += usage['completion_tokens']
                record['usage'] = usage
                record['finish_reason'] = response_body['choices'][0].get('finish_reason')
                record['response_model'] = response_body.get('model')
            except (ValueError, KeyError, IndexError, TypeError):
                record['usage_error'] = 'missing or invalid usage'
            record['reported_input_total'] = input_total
            record['reported_output_total'] = output_total
            record['estimated_spend_usd'] = (input_total * INPUT_RATE
                                             + output_total * OUTPUT_RATE) / 1_000_000
            ledger.write(json.dumps(record) + '\n')
            ledger.flush()
            if status == 200 and 'usage' in record:
                completed += 1
            else:
                print(f'HTTP {status} or missing usage at {index}; stopping without retry', flush=True)
                break
            if index % 24 == 0 or index == len(schedule):
                print(f'{index}/{len(schedule)} completed; reported USD {record["estimated_spend_usd"]:.6f}',
                      flush=True)
            if index < len(schedule):
                time.sleep(WAIT_SECONDS)
    print(f'Finished: {completed} successful requests; {input_total} input and '
          f'{output_total} output tokens; estimated USD '
          f'{(input_total * INPUT_RATE + output_total * OUTPUT_RATE) / 1_000_000:.6f}', flush=True)


if __name__ == '__main__':
    main()
