#!/usr/bin/env python3
"""Summarize diagnostic field reads, never use these runs for latency claims."""
import collections
import csv
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
rows = []
config = next(line for line in (root / 'environment.txt').read_text().splitlines() if line.startswith('frames='))
repeats = int(dict(item.split('=', 1) for item in config.split())['repeats'])
paths = [root / f'{kind}-s{size}-t{threads}-r{repeat}.log'
         for kind in ('bytes', 'refs', 'zeros') for size in (1048568, 1048576, 1048584)
         for threads in (1, 4) for repeat in range(1, repeats + 1)]
for path in sorted(paths):
    counts = collections.Counter()
    current = None
    published = {}
    first_reads = collections.Counter()
    draining = False
    reports = collections.defaultdict(dict)
    large_categories = collections.Counter()
    lines = path.read_text().splitlines()
    end = next(line for line in lines if line.startswith('STRESS-END,'))
    primary_bytes = int(dict(item.split('=', 1) for item in end.split(',')[1:])['primary_allocated'])
    for line in lines:
        if not line.startswith('GC-SCAN-'):
            continue
        parts = line.split(',')
        fields = dict(item.split('=', 1) for item in parts[1:])
        if parts[0] == 'GC-SCAN-PUBLISH':
            current = fields['block']
            published[current] = int(fields.get('bytes', primary_bytes))
        elif parts[0] == 'GC-SCAN-DRAIN':
            draining = True
        elif parts[0] == 'GC-SCAN-LARGE':
            if fields['block'] not in published:
                raise ValueError(f'{path}: scan of unknown primary')
            key = int(fields['cycle']), fields['block']
            first_reads[key] += int(fields['first_bytes'])
            if first_reads[key] > published[fields['block']]:
                raise ValueError(f'{path}: first reads exceed object size')
            phase = 'drain' if draining else 'frames'
            ownership = 'current' if fields['block'] == current else 'replaced'
            source = int(fields['source'])
            if source not in range(4):
                raise ValueError('invalid source')
            for repeat, field in enumerate(('first_bytes', 'repeat_bytes')):
                n = int(fields[field])
                counts[phase, ownership, repeat, source] += n
                large_categories[int(fields['cycle']), repeat, source] += n
                if fields['black'] == '1':
                    counts['black'] += n
                counts['large'] += n
        elif parts[0] == 'GC-SCAN-TOTAL':
            cycle = int(fields['cycle'])
            key = int(fields['repeat']), int(fields['source'])
            if key in reports[cycle]:
                raise ValueError(f'{path}: duplicate cycle report')
            reports[cycle][key] = int(fields['bytes'])
    if not reports or any(len(r) != 8 for r in reports.values()):
        raise ValueError(f'{path}: missing complete cycle reports')
    for (cycle, repeat, source), n in large_categories.items():
        if cycle not in reports or n > reports[cycle][repeat, source]:
            raise ValueError(f'{path}: large reads exceed reported category')
    total = sum(sum(r.values()) for r in reports.values())
    if counts['large'] > total:
        raise ValueError(f'{path}: large reads exceed total reads')
    row = {'run': path.stem, 'all_mib': total / 2**20}
    for repeat, label in enumerate(('first', 'repeat')):
        row[label + '_mib'] = sum(r[repeat, s] for r in reports.values() for s in range(4)) / 2**20
    for source, label in enumerate(('discovery', 'software', 'kernel', 'both')):
        row[label + '_mib'] = sum(r[rp, source] for r in reports.values() for rp in range(2)) / 2**20
    for phase in ('frames', 'drain'):
        for ownership in ('current', 'replaced'):
            row[f'{phase}_{ownership}_large_mib'] = sum(counts[phase, ownership, rp, s] for rp in range(2) for s in range(4)) / 2**20
    row['black_large_mib'] = counts['black'] / 2**20
    rows.append(row)
if not rows:
    raise ValueError('no scan logs')
with (root / 'scan-summary.csv').open('w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=rows[0])
    writer.writeheader()
    writer.writerows(rows)
for row in rows:
    print(row['run'] + ': ' + ', '.join(f'{k}={v:.2f}' for k, v in row.items() if k != 'run'))
