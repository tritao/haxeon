#!/usr/bin/env python3
"""Pair typed interface implementations with the receiver last in the old dispatch chain.

Example: --compiler boxed=/disk/control.hl --compiler table=/disk/candidate.hl
Outputs and generated guests go to a new, empty disk directory. Every process
checks its result and records allocation counts as well as timing samples.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "tests/bench/typed-interface-dispatch.template.hx"
JS = r'''
const e = new WebAssembly.Instance(new WebAssembly.Module(require('fs').readFileSync(process.argv[1])), {}).exports;
e['Scale.prepare'](0);
for (let i=0;i<2;i++) if(e['Scale.perform'](100000)!==4200000) throw Error('warmup');
const samples=[];
for(let i=0;i<5;i++) {
 const start=performance.now(), result=e['Scale.perform'](100000);
 samples.push((performance.now()-start)/1000);
 if(result!==4200000) throw Error('result');
}
const counter=e.__allocation_count||e['haxeon.memory.allocation_count'], allocations={};
for(const n of [8,1024]) {
 const before=counter(),result=e['Scale.perform'](n);
 if(result!==42*n) throw Error('census result');
 allocations[n]=counter()-before;
}
console.log(JSON.stringify({samples,allocations}));
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", action="append", required=True, metavar="LABEL=FILE")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=3)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--cpu", type=int, default=2)
    args = parser.parse_args()
    compilers = {}
    for item in args.compiler:
        name, separator, value = item.partition("=")
        if not separator or not name or not name.replace("-", "").isalnum() or name in compilers:
            parser.error("Each compiler needs a unique alphanumeric label and an existing file")
        path = Path(value).resolve()
        if not path.is_file():
            parser.error(f"Missing compiler: {path}")
        compilers[name] = path
    if args.pairs < 1 or args.jobs < 1:
        parser.error("pairs and jobs must be positive")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new output directory; recorded measurements are never overwritten")
    if str(output).startswith("/dev/shm/"):
        parser.error("Use disk storage for builds and captures")
    if shutil.disk_usage(ROOT).free < 5 * 1024**3:
        parser.error("Clean your own outputs before building below 5 GiB free")
    output.mkdir(parents=True, exist_ok=True)
    (output / "configuration.json").write_text(json.dumps({"compilers": {k:str(v) for k,v in compilers.items()},
        "pairs":args.pairs,"calls":100000,"samples":5,"cpu":args.cpu}, indent=2)+"\n")
    for n in (1,8,32):
        directory = output / f"source-{n}"
        directory.mkdir()
        implementations = "\n".join(f"class Impl{i:02} extends BaseImpl {{ public function new() super(); public override function read():Packet return payload; }}" for i in range(1,n))
        cases = " ".join(f"case {i}: reader=new Impl{i:02}();" for i in range(1,n))
        source = TEMPLATE.read_text().replace("/* IMPLEMENTATIONS */", implementations).replace("/* RECEIVERS */", cases)
        (directory / f"DispatchScale{n}.hx").write_text(source)
    targets = ("hl", "wasm32", "wasm-gc")
    jobs = [(target,inline,n,label) for target in targets for inline in (0,1) for n in (1,8,32) for label in compilers]

    def build(job):
        target, inline, n, label = job
        stem = f"{target}-{inline}-{n}-{label}"
        guest = output / (stem + (".hl" if target == "hl" else ".wasm"))
        source = output / f"source-{n}"
        flags = [] if target == "hl" else ["--wasm-memory-stats" if target == "wasm32" else "--wasm-gc-allocation-count", "--export=Scale.prepare", "--export=Scale.perform"]
        command = [str(ROOT/"scripts/hl"), str(compilers[label]), "--target="+target, "--output="+str(guest), f"--entry=DispatchScale{n}", "--root="+str(source), "--root=stdlib", *flags, str(source/f"DispatchScale{n}.hx")]
        run = subprocess.run(command, cwd=ROOT, env=dict(os.environ, TMPDIR=str(output), HAXEON_INLINE=str(inline)), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (output/(stem+"-build.log")).write_text(run.stdout)
        if run.returncode:
            raise RuntimeError(f"Build failed: {stem}; see its build log")
        return stem

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for stem in pool.map(build, jobs):
            print("BUILT", stem, flush=True)
    records = []
    labels = list(compilers)
    for target in targets:
        for inline in (0,1):
            for n in (1,8,32):
                for pair in range(args.pairs):
                    shift = pair % len(labels)
                    for label in labels[shift:] + labels[:shift]:
                        stem = f"{target}-{inline}-{n}-{label}"
                        guest = output/(stem+(".hl" if target=="hl" else ".wasm"))
                        command = ["taskset", "-c", str(args.cpu), *([str(ROOT/"scripts/hl"), str(guest)] if target=="hl" else ["node", "-e", JS, str(guest)])]
                        run = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                        (output/f"{stem}-pair-{pair}.log").write_text(run.stdout)
                        if run.returncode != (42 if target=="hl" else 0):
                            raise RuntimeError(f"Run failed: {stem} pair {pair}; see its log")
                        record = {"target":target,"inline":inline,"implementers":n,"version":label,"pair":pair}
                        if target=="hl":
                            record["samples"] = [float(line.split()[1]) for line in run.stdout.splitlines() if line.startswith("SAMPLE ")]
                            record["exactBytes"] = {line.split()[1]:float(line.split()[2]) for line in run.stdout.splitlines() if line.startswith("BYTES ")}
                        else:
                            record.update(json.loads(run.stdout))
                        if len(record["samples"])!=5 or set(record.get("exactBytes", record.get("allocations", {})))!={"8","1024"}:
                            raise RuntimeError("Incomplete timing or allocation record")
                        with (output/"pairs.jsonl").open("a") as stream:
                            stream.write(json.dumps(record)+"\n")
                        records.append(record)
                        print(stem, pair, statistics.median(record["samples"])*1e4, "ns/call", flush=True)
    summary=[]
    for target in targets:
        for inline in (0,1):
            for n in (1,8,32):
                row={"target":target,"inline":inline,"implementers":n}
                for label in labels:
                    selected=[r for r in records if r["target"]==target and r["inline"]==inline and r["implementers"]==n and r["version"]==label]
                    row[label]={"nsPerCall":statistics.median([s*1e4 for r in selected for s in r["samples"]]),
                        "allocations":[r.get("exactBytes",r.get("allocations")) for r in selected]}
                summary.append(row)
    (output/"summary.json").write_text(json.dumps(summary,indent=2)+"\n")


if __name__ == "__main__":
    main()
