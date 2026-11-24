"""Report convergence under mutation separately from post-load quiescent drain."""
import csv
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def stats(values):
    if not values:
        return 'no completed cycle samples'
    values = sorted(values)
    return f'p50={values[(len(values)-1)//2]:.3f} p99={values[(len(values)-1)*99//100]:.3f} max={values[-1]:.3f}'

config_line = next(line for line in (root / 'environment.txt').read_text().splitlines() if line.startswith('frames='))
config = dict(item.split('=') for item in config_line.split())
paths = [root / f'{workload}-t{threads}-r{repeat}.csv'
         for workload in ('arrays', 'graphs', 'overload', 'rewrite')
         for threads in (1, 4) for repeat in range(1, int(config['repeats']) + 1)]
for path in paths:
    with path.open() as source:
        rows = list(csv.DictReader(source))
    if len(rows) != int(config['frames']):
        raise SystemExit(f'FAIL: empty samples: {path.name}')
    ends = [line for line in path.with_suffix('.log').read_text().splitlines() if line.startswith('STRESS-END,')]
    if len(ends) != 1:
        raise SystemExit(f'FAIL: missing successful drain/verification: {path.name}')
    end = dict(item.split('=') for item in ends[0].split(',')[1:])
    last = rows[-1]
    durations, previous, unsampled = [], 0, 0
    for row in rows:
        completed = int(row['cycles_completed'])
        if completed > previous:
            durations.append(float(row['last_cycle_ms']))
            unsampled += completed - previous - 1
        previous = completed
    tracking = int(last['tracking_fallbacks'])
    if int(last['full_collections']) != tracking + int(last['pressure_fallbacks']):
        raise SystemExit(f'FAIL: unexplained synchronous collection: {path.name}')
    if tracking:
        raise SystemExit(f'FAIL: tracking failed in {path.name}')
    active_id, active_start, max_age_frames = None, 0, 0
    for row in rows:
        if row['pending'] == '1':
            if row['cycles_started'] != active_id:
                active_id, active_start = row['cycles_started'], int(row['frame'])
            max_age_frames = max(max_age_frames, int(row['frame']) - active_start + 1)
        else:
            active_id = None
    frames = [float(r['frame_ms']) for r in rows]
    baseline = int(end['baseline_heap'])
    peak = max(int(r['heap_bytes']) for r in rows)
    tail = rows[len(rows)*3//4:]
    print(path.stem)
    print(f"  frames={len(rows)} cycles_started={last['cycles_started']} incremental_completed={last['cycles_completed']} pressure_fallbacks={last['pressure_fallbacks']} tracking_fallbacks={tracking} full_collections={last['full_collections']} pending_at_end={last['pending']}")
    print(f"  frame_ms {stats(frames)} over_16.67ms={sum(v > 1000/60 for v in frames)}")
    print(f"  allocation_ms {stats([float(r['allocation_ms']) for r in rows])}")
    print(f"  completed_cycle_wall_ms {stats(durations)} unsampled_completions={unsampled}")
    print(f"  max_pending_age_frames={max_age_frames} max_pending_cycle_age_ms={max(float(r['cycle_age_ms']) for r in rows):.3f} max_dirty_pages={max(int(r['dirty_pages']) for r in rows)} max_mark_objects={max(int(r['mark_objects']) for r in rows)} end_dirty_pages={last['dirty_pages']} end_mark_objects={last['mark_objects']}")
    print(f"  heap_mib baseline={baseline/2**20:.2f} peak={peak/2**20:.2f} end={int(last['heap_bytes'])/2**20:.2f} tail_range={min(int(r['heap_bytes']) for r in tail)/2**20:.2f}..{max(int(r['heap_bytes']) for r in tail)/2**20:.2f} after_drain={int(end['heap_after_drain'])/2**20:.2f} after_major={int(end['heap_after_major'])/2**20:.2f}")
    print(f"  quiescent_drain_steps={end['drain_steps']} drain_ms={end['drain_ms']}")
