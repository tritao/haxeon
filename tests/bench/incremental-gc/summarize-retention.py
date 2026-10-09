"""Completion snapshots only; distinguish under-load cycles from final drain."""
import csv
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
results = []
for kind in ('refs', 'zeros', 'bytes'):
    cycles = {}
    drain = False
    for line in (root / f'{kind}.log').read_text().splitlines():
        if line == 'GC-SCAN-DRAIN':
            drain = True
        if not line.startswith('GC-RETENTION,'):
            continue
        row = {k: int(v) for k, v in (x.split('=', 1) for x in line.split(',')[1:])}
        cycle = cycles.setdefault(row['cycle'], dict(kind=kind, cycle=row['cycle'], drain=int(drain), marked_bytes=0, unreachable_bytes=0, black_bytes=0, black_unreachable_bytes=0, **{f'black_dead_age{i}_bytes': 0 for i in range(4)}))
        size = row['bytes']
        cycle['marked_bytes'] += size
        if not row['reachable']:
            cycle['unreachable_bytes'] += size
        if row['black']:
            cycle['black_bytes'] += size
            if not row['reachable']:
                cycle['black_unreachable_bytes'] += size
                cycle[f"black_dead_age{row['age_bucket']}_bytes"] += size
    assert cycles, f'{kind}: no completed snapshots'
    frames = list(csv.DictReader((root / f'{kind}.csv').open()))
    assert frames and int(frames[-1]['tracking_fallbacks']) == 0
    assert int(frames[-1]['cycles_completed']) == sum(not r['drain'] for r in cycles.values())
    results.extend(cycles.values())
    active = [r for r in cycles.values() if not r['drain']]
    dead = [r['black_unreachable_bytes'] / 2**20 for r in active]
    print(f'{kind}: {len(active)} under-load completions; black unreachable MiB per completion: ' + (f'min={min(dead):.2f}, max={max(dead):.2f}' if dead else 'none; inspect drain separately'))
with (root / 'retention-summary.csv').open('w') as output:
    writer = csv.DictWriter(output, fieldnames=results[0])
    writer.writeheader()
    writer.writerows(results)
