"""Summarize diagnostic pauses; logging/validation runs are not latency baselines."""
import pathlib
import statistics
import sys

for filename in sys.argv[1:]:
    path = pathlib.Path(filename)
    marking, cleanup = [], []
    for line in path.read_text().splitlines():
        if line == 'GC-LATENCY-DRAIN':
            break
        if line.startswith(('GC-LATENCY,', 'GC-RECLAIM,')):
            row = dict(x.split('=', 1) for x in line.split(',')[1:])
            (cleanup if line.startswith('GC-RECLAIM,') else marking).append(row)
    assert marking or cleanup, f'{path}: no diagnostic pauses'
    print(path)
    for name, rows in (('marking', marking), ('publication', [r for r in marking if r['done'] == '1']), ('reclamation', cleanup)):
        if not rows:
            continue
        print(f'  {name}: {len(rows)} pauses')
        for field in ('pause_ms', 'roots_ms', 'capture_ms', 'finish_ms', 'finalizers_ms', 'reclaim_ms', 'rearm_ms'):
            values = sorted(float(r[field]) for r in rows if field in r)
            if values:
                print(f'    {field}: median={statistics.median(values):.6f}, p99={values[(len(values)-1)*99//100]:.6f}, max={values[-1]:.6f}')
