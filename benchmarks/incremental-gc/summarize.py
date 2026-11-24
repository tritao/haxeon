"""Summarize raw frame samples and separate diagnostic phase runs."""
import csv
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def stats(values):
    values = sorted(values)
    return f'p50={values[(len(values)-1)//2]:.3f} p99={values[(len(values)-1)*99//100]:.3f} max={values[-1]:.3f}'

for threads in (1, 4):
    for mode in (0, 1):
        rows = []
        for path in sorted(root.glob(f't{threads}-m{mode}-r*.csv')):
            with path.open() as source:
                rows.extend(csv.DictReader(source))
        frames = [float(r['frame_ms']) for r in rows]
        gc = [float(r['gc_ms']) for r in rows if r['stepped'] == '1']
        allocations = [float(r['allocation_ms']) for r in rows]
        completed = sum(r['done'] == '1' for r in rows)
        print(f'threads={threads} mode={"incremental" if mode else "full"} frames={len(rows)} completed_cycles={completed}')
        print(f'  frame_ms {stats(frames)} over_16.67ms={sum(v > 1000/60 for v in frames)}')
        print(f'  allocation_ms {stats(allocations)}')
        print(f'  gc_call_ms {stats(gc)}')
    phases = []
    for line in (root / f'phases-t{threads}.log').read_text().splitlines():
        if line.startswith('GC-LATENCY,'):
            phases.append(dict(item.split('=') for item in line.split(',')[1:]))
    if not phases:
        raise SystemExit('FAIL: no GC phase samples')
    if any(r['ok'] != '1' for r in phases):
        raise SystemExit('FAIL: dirty tracking failed during benchmark')
    print(f'threads={threads} diagnostic phases (ms; finish includes finalizers):')
    for key in phases[0]:
        if key.endswith('_ms'):
            print(f'  {key} {stats([float(r[key]) for r in phases])}')
    worst = max(phases, key=lambda r: float(r['pause_ms']))
    print('  worst_slice ' + ' '.join(f'{k}={v}' for k, v in worst.items()))
