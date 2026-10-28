#!/usr/bin/env python3
"""Calculate descriptive, paired statistics for saved Codestral responses."""

import argparse
from collections import defaultdict
import csv
import json
from pathlib import Path
import random
import re
import statistics


ANCHORS = {
    'tex_expression': '= z^2\\)',
    'tex_operator': '+ y^n = z^n \\]',
    'tex_newline': '\\[ x^n + y^n = z^n \\]',
    'lua_expression': 'local language = utils.add_language_comment()',
    'lua_operator': ".. tab .. '\\n' .. context_before_cursor",
    'lua_newline': '---@class minuet.ChatInput',
    'tex_operator_changed': '- y^n = w^n \\]',
}


def normalized(value: str) -> str:
    return re.sub(r'\s+', ' ', value).strip()


def longest_common_substring(left: str, right: str) -> tuple[int, str, int, int]:
    previous = [0] * (len(right) + 1)
    best = (0, '', -1, -1)
    for left_index, char in enumerate(left):
        current = [0] * (len(right) + 1)
        for right_index, other in enumerate(right):
            if char == other:
                length = previous[right_index] + 1
                current[right_index + 1] = length
                if length > best[0]:
                    best = (length, left[left_index + 1 - length:left_index + 1],
                            left_index + 1 - length, right_index + 1 - length)
        previous = current
    return best


def wilson(successes: int, total: int) -> list[float]:
    if not total:
        return [0.0, 0.0]
    z = 1.959963984540054
    p = successes / total
    center = (p + z*z/(2*total)) / (1 + z*z/total)
    margin = z * ((p*(1-p)/total + z*z/(4*total*total)) ** 0.5) / (1 + z*z/total)
    return [center-margin, center+margin]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('run_dir', type=Path)
    args = parser.parse_args()
    run_dir = args.run_dir
    fixtures = {item['id']: item for item in json.loads((run_dir / 'fixtures.json').read_text())}
    rows = []
    for line in (run_dir / 'ledger.jsonl').read_text().splitlines():
        entry = json.loads(line)
        if entry['status'] != 200 or 'usage' not in entry:
            continue
        response = json.loads((run_dir / f'{entry["stem"]}.response.json').read_text())
        content = response['choices'][0]['message']['content']
        fixture = fixtures[entry['fixture']]
        completion = normalized(content)
        original_suffix = normalized(fixture['suffix'])
        active_suffix = normalized({
            'original': fixture['suffix'], 'empty': '', 'newline': '\n',
            'changed': fixture['changed_suffix'],
        }[entry['condition']])
        original_match = longest_common_substring(completion, original_suffix)
        active_match = longest_common_substring(completion, active_suffix)
        prefix = normalized(fixture['prefix'])
        original_prefix = 0
        for left_char, right_char in zip(completion, original_suffix):
            if left_char != right_char:
                break
            original_prefix += 1
        rows.append({
            'request': entry['request'], 'fixture': entry['fixture'],
            'condition': entry['condition'], 'repetition': entry['repetition'],
            'finish_reason': entry['finish_reason'], 'completion': content,
            'completion_chars': len(content),
            'prompt_tokens': entry['usage']['prompt_tokens'],
            'completion_tokens': entry['usage']['completion_tokens'],
            'original_match_chars': original_match[0],
            'original_match_text': original_match[1],
            'original_match_completion_position': original_match[2],
            'original_match_suffix_position': original_match[3],
            'original_match_in_prompt': bool(original_match[1] and original_match[1] in prefix),
            'active_match_chars': active_match[0],
            'active_match_text': active_match[1],
            'active_match_in_prompt': bool(active_match[1] and active_match[1] in prefix),
            'original_prefix_chars': original_prefix,
            'original_match_ge12': int(original_match[0] >= 12),
            'original_match_ge20': int(original_match[0] >= 20),
            'active_match_ge12': int(active_match[0] >= 12),
            'active_match_ge20': int(active_match[0] >= 20),
        })
    (run_dir / 'response_metrics.json').write_text(json.dumps(rows, indent=2) + '\n')
    with (run_dir / 'response_metrics.csv').open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=[key for key in rows[0] if key != 'completion'],
                                lineterminator='\n')
        writer.writeheader()
        writer.writerows({key: value for key, value in row.items() if key != 'completion'} for row in rows)

    groups = defaultdict(list)
    for row in rows:
        groups[(row['fixture'], row['condition'])].append(row)
        groups[('all', row['condition'])].append(row)
    group_stats = []
    for (fixture, condition), items in sorted(groups.items()):
        count12 = sum(item['original_match_ge12'] for item in items)
        count20 = sum(item['original_match_ge20'] for item in items)
        active12 = sum(item['active_match_ge12'] for item in items)
        active20 = sum(item['active_match_ge20'] for item in items)
        group_stats.append({
            'fixture': fixture, 'condition': condition, 'n': len(items),
            'match_ge12': count12, 'match_ge20': count20,
            'active_match_ge12': active12, 'active_match_ge20': active20,
            'unique_completions': len({item['completion'] for item in items}),
            'original_match_in_prompt': sum(item['original_match_in_prompt'] for item in items),
            'match_ge12_wilson95': wilson(count12, len(items)),
            'match_ge20_wilson95': wilson(count20, len(items)),
            'mean_match_chars': statistics.mean(item['original_match_chars'] for item in items),
            'median_match_chars': statistics.median(item['original_match_chars'] for item in items),
            'mean_completion_tokens': statistics.mean(item['completion_tokens'] for item in items),
            'length_finishes': sum(item['finish_reason'] == 'length' for item in items),
        })
    by_pair = {(row['fixture'], row['repetition'], row['condition']): row for row in rows}
    paired = []
    fixture_ids = list(fixtures)
    rng = random.Random(20261027)
    for control in ('empty', 'newline', 'changed'):
        for threshold in (12, 20):
            differences = []
            per_fixture = {}
            for fixture in fixture_ids:
                local = []
                for repetition in range(1, 10):
                    original = by_pair.get((fixture, repetition, 'original'))
                    other = by_pair.get((fixture, repetition, control))
                    if original is not None and other is not None:
                        local.append(original[f'original_match_ge{threshold}']
                                     - other[f'original_match_ge{threshold}'])
                per_fixture[fixture] = local
                differences.extend(local)
            boot = []
            for _ in range(10000):
                sampled = [rng.choice(fixture_ids) for _ in fixture_ids]
                values = [value for fixture in sampled for value in per_fixture[fixture]]
                if values:
                    boot.append(statistics.mean(values))
            boot.sort()
            paired.append({
                'control': control, 'threshold_chars': threshold,
                'matched_pairs': len(differences),
                'risk_difference': statistics.mean(differences) if differences else None,
                'cluster_bootstrap95': [boot[int(0.025 * len(boot))],
                                        boot[int(0.975 * len(boot))]] if boot else None,
                'original_only': sum(value == 1 for value in differences),
                'control_only': sum(value == -1 for value in differences),
                'both_or_neither': sum(value == 0 for value in differences),
            })
    totals = {
        'successful_requests': len(rows),
        'input_tokens': sum(row['prompt_tokens'] for row in rows),
        'output_tokens': sum(row['completion_tokens'] for row in rows),
        'estimated_usage_usd': (
            sum(row['prompt_tokens'] for row in rows) * 0.30
            + sum(row['completion_tokens'] for row in rows) * 0.90
        ) / 1_000_000,
    }
    anchor_counts = []
    for anchor_id, anchor in ANCHORS.items():
        fixture = anchor_id.removesuffix('_changed')
        for condition in ('original', 'empty', 'newline', 'changed'):
            items = groups.get((fixture, condition), [])
            anchor_counts.append({
                'anchor_id': anchor_id, 'anchor': anchor,
                'condition': condition, 'n': len(items),
                'matches': sum(normalized(anchor) in normalized(item['completion'])
                               for item in items),
            })
    summary = {'totals': totals, 'groups': group_stats, 'paired': paired,
               'anchor_counts': anchor_counts,
               'metric_definition': 'Longest contiguous common substring after whitespace collapse; comparisons use the original suffix for every condition. Thresholds are characters, not tokens.',
               'uncertainty_note': 'Wilson intervals describe observed call proportions; paired bootstrap resamples eight fixtures as clusters and is conditional on these hand-picked fixtures.'}
    (run_dir / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f'{totals["successful_requests"]} successful responses; '
          f'{totals["input_tokens"]} input and {totals["output_tokens"]} output tokens; '
          f'estimated USD {totals["estimated_usage_usd"]:.7f}; '
          f'metrics in {run_dir}')


if __name__ == '__main__':
    main()
