"""Optional plot: python3 plot-convergence.py OUTPUT_DIR [SECOND_OUTPUT_DIR]."""
import csv
import pathlib
import sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

roots = [pathlib.Path(arg) for arg in sys.argv[1:]]
if not roots:
    raise SystemExit('Usage: plot-convergence.py OUTPUT_DIR [SECOND_OUTPUT_DIR]')
fig, axes = plt.subplots(2, 4, figsize=(15, 7), sharex='col')
for root in roots:
    line = next(line for line in (root / 'environment.txt').read_text().splitlines() if line.startswith('frames='))
    config = dict(item.split('=') for item in line.split())
    mode = 'automatic + explicit' if config['auto'] == '1' else 'explicit only'
    label = f"{mode}, {float(config['budget_us'])/1000:g} ms"
    for col, workload in enumerate(('rewrite', 'arrays', 'graphs', 'overload')):
        with (root / f'{workload}-t1-r1.csv').open() as source:
            rows = list(csv.DictReader(source))
        frames = [int(row['frame']) for row in rows]
        heap = [int(row['heap_bytes'])/2**20 for row in rows]
        latency = [float(row['frame_ms']) for row in rows]
        plot, = axes[0, col].plot(frames, heap, label=label, linewidth=1)
        axes[1, col].plot(frames, latency, color=plot.get_color(), linewidth=.8)
        previous = 0
        for row in rows:
            current = int(row['pressure_fallbacks'])
            if current > previous:
                axes[0, col].scatter(int(row['frame']), int(row['heap_bytes'])/2**20,
                                     color=plot.get_color(), marker='x', s=24, zorder=3)
            previous = current
        axes[0, col].set_title(workload)
        axes[1, col].set_xlabel('Simulated frame')
for col in range(4):
    axes[1, col].axhline(1000/60, color='gray', linestyle='--', linewidth=.8)
    for ax in axes[:, col]:
        ax.grid(alpha=.2)
axes[0, 0].set_ylabel('Allocated heap pages (MiB)')
axes[1, 0].set_ylabel('Frame work (ms)')
handles, labels = axes[0, 0].get_legend_handles_labels()
fig.legend(handles, labels, loc='upper center', ncol=len(roots))
fig.suptitle('Sustained mutation: one marking worker, first repetition', y=.95)
fig.text(.5, .01, '× marks pressure fallback; dashed line is 16.67 ms. Rendering and frame sleeps are excluded. Heap pages include cached/floating garbage.', ha='center', fontsize=9)
fig.tight_layout(rect=(0, .04, 1, .91))
for suffix in ('png', 'svg'):
    fig.savefig(roots[0] / f'convergence-comparison.{suffix}', dpi=160)
