"""Optional Matplotlib plot of the boundary experiment's comparison.csv."""
import csv
import pathlib
import statistics
import sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

root=pathlib.Path(sys.argv[1])
threads=int(sys.argv[2]) if len(sys.argv)>2 else 1
with (root/'comparison.csv').open() as source:
    rows=[row for row in csv.DictReader(source) if int(row['threads'])==threads]
if not rows:
    raise SystemExit('No samples for requested worker count')
sizes=(1048568,1048576,1048584)
metrics=(('cycles','Incremental cycles completed'),('pressure','Pressure fallbacks'),('heap','Peak heap pages (MiB)'),('alloc','Allocation/initialization p99 (ms)'),('gc','GC call p99 (ms)'),('p99','Frame work p99 (ms)'))
fig,axes=plt.subplots(2,3,figsize=(14,8),sharex=True)
for kind,label,color,offset in (('bytes','Pointer-free, identical bits','#2878b5',-.12),('zeros','Pointer array, all null','#d89020',0),('refs','Pointer array, references','#bf4242',.12)):
    for ax,(key,title) in zip(axes.flat,metrics):
        groups=[[float(row[key]) for row in rows if row['kind']==kind and int(row['size'])==size] for size in sizes]
        means=[statistics.mean(group) for group in groups]
        ax.errorbar([i+offset for i in range(3)],means,
                    yerr=([mean-min(group) for mean,group in zip(means,groups)],
                          [max(group)-mean for mean,group in zip(means,groups)]),
                    color=color,label=label,marker='o',capsize=4,linewidth=1)
        ax.set_title(title);ax.grid(axis='y',alpha=.2)
        ax.set_xticks(range(3),('1 MiB − 8 B','1 MiB','1 MiB + 8 B'))
        ax.set_xlim(-.4,2.4)
for ax in axes[1]:
    ax.set_xlabel('Requested primary object size')
handles,labels=axes[0,0].get_legend_handles_labels()
fig.legend(handles,labels,loc='upper center',ncol=3)
fig.suptitle(f'Large-object boundary: {threads} marking worker(s), means and observed repeat ranges',y=.94)
fig.text(.5,.015,'4 MiB allocated payload/frame with pointer-free filler. Heap pages include allocator waste/caches; timings exclude validation and rendering.',ha='center',fontsize=9)
fig.tight_layout(rect=(0,.045,1,.91))
for suffix in ('png','svg'):
    fig.savefig(root/f'large-object-t{threads}.{suffix}',dpi=160)
