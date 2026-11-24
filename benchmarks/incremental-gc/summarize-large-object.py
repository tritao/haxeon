"""Paired type/size controls at equal measured allocator payload volume."""
import csv
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
line = next(line for line in (root/'environment.txt').read_text().splitlines() if line.startswith('frames='))
config = dict(item.split('=') for item in line.split())
print(f"Equal allocated payload: {int(config['volume'])/2**20:g} MiB/frame; budget={config['budget_us']} us; frames={config['frames']}")
print('Heap pages include allocator overhead, cached pages and floating garbage.')
print('kind,size_requested,threads,repeat,primary_allocated,cycles,pressure,peak_heap_mib,alloc_p99_ms,gc_p99_ms,frame_p99_ms,frame_max_ms,drain_steps')
results = []
for kind in ('bytes','zeros','refs'):
    for size in (1048568,1048576,1048584):
        for threads in (1,4):
            for repeat in range(1,int(config['repeats'])+1):
                stem=f'{kind}-s{size}-t{threads}-r{repeat}'
                with (root/f'{stem}.csv').open() as source:
                    rows=list(csv.DictReader(source))
                if len(rows)!=int(config['frames']):
                    raise SystemExit(f'FAIL: incomplete run {stem}')
                ends=[s for s in (root/f'{stem}.log').read_text().splitlines() if s.startswith('STRESS-END,')]
                if len(ends)!=1:
                    raise SystemExit(f'FAIL: missing verification {stem}')
                end=dict(item.split('=') for item in ends[0].split(',')[1:])
                if int(end['frame_allocated'])!=int(config['volume']) or int(end['primary_requested'])!=size:
                    raise SystemExit(f'FAIL: wrong volume/size {stem}')
                for before,after in zip(rows,rows[1:]):
                    if int(after['allocated_bytes'])-int(before['allocated_bytes'])!=int(config['volume']):
                        raise SystemExit(f'FAIL: unequal allocated payload {stem}')
                last=rows[-1]
                if int(last['tracking_fallbacks']) or int(last['full_collections'])!=int(last['pressure_fallbacks']):
                    raise SystemExit(f'FAIL: unexpected full collection {stem}')
                def p99(field):
                    values=sorted(float(row[field]) for row in rows)
                    return values[(len(values)-1)*99//100]
                result=dict(kind=kind,size=size,threads=threads,repeat=repeat,primary=int(end['primary_allocated']),cycles=int(last['cycles_completed']),pressure=int(last['pressure_fallbacks']),heap=max(int(r['heap_bytes']) for r in rows)/2**20,alloc=p99('allocation_ms'),gc=p99('gc_ms'),p99=p99('frame_ms'),maximum=max(float(r['frame_ms']) for r in rows),drain=int(end['drain_steps']))
                results.append(result)
                print(f"{kind},{size},{threads},{repeat},{result['primary']},{result['cycles']},{result['pressure']},{result['heap']:.2f},{result['alloc']:.3f},{result['gc']:.3f},{result['p99']:.3f},{result['maximum']:.3f},{result['drain']}")
with (root/'comparison.csv').open('w') as output:
    writer=csv.DictWriter(output,fieldnames=list(results[0]))
    writer.writeheader();writer.writerows(results)
