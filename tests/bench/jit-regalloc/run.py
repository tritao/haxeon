#!/usr/bin/env python3
"""Opt-in allocator micros: Eval oracle, pinned alternating pairs, perf and JIT stats."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
PATTERNS = ['baseline', 'hot', 'cold', 'pressure', 'nested', 'conditional']


def run(command, env):
    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{command}: {result.stderr[-2000:]}')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', default=os.environ.get('HAXEON_COMPILER_HL', 'out/regalloc/compiler.hl'))
    parser.add_argument('--work', default='out/regalloc/micro-results')
    parser.add_argument('--iterations', type=int, default=300000000)
    parser.add_argument('--pairs', type=int, default=9)
    parser.add_argument('--cpu', type=int, default=0)
    parser.add_argument('--modes', default='0,4', help='two HL_JIT_REGOPT masks')
    parser.add_argument('--patterns', default=','.join(PATTERNS))
    parser.add_argument('--allow-busy', action='store_true')
    args = parser.parse_args()
    modes = [int(value, 0) for value in args.modes.split(',')]
    if len(modes) != 2 or args.pairs < 1:
        parser.error('provide two masks and at least one pair')
    work = (ROOT / args.work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, LD_LIBRARY_PATH=f'{ROOT}/out:{ROOT}/.tools/hashlink',
               HAXE_STD_PATH=str(ROOT / '.tools/haxe/std'))
    env.pop('HL_JIT_REGSTATS', None)
    env.pop('HL_JIT_REGPROBE', None)
    env['HAXEON_INLINE'] = '0'
    hl = str(ROOT / '.tools/hashlink/hl')
    haxe = str(ROOT / '.tools/haxe/haxe')
    bytecode = work / 'micro.hl'
    build = run([hl, args.compiler, '--target=hl', f'--output={bytecode}',
                 '--entry=RegallocBench', '--root=tests/bench/jit-regalloc',
                 'tests/bench/jit-regalloc/RegallocBench.hx'], env)
    (work / 'compile.log').write_text(build.stdout + build.stderr)
    rows = []
    for pattern in args.patterns.split(','):
        if pattern not in PATTERNS:
            parser.error(f'unknown pattern {pattern}')
        oracle = run([haxe, '-cp', 'tests/bench/jit-regalloc', '--run',
                      'RegallocBench', pattern, '1000'], env).stdout
        for mode in modes:
            actual = run([hl, str(bytecode), pattern, '1000'], dict(env, HL_JIT_REGOPT=str(mode))).stdout
            if actual != oracle:
                raise RuntimeError(f'{pattern}/{mode}: {actual!r} != Eval {oracle!r}')
        while not args.allow_busy and os.getloadavg()[0] > 4:
            print(f'Waiting for load <= 4; current {os.getloadavg()[0]:.2f}', flush=True)
            time.sleep(30)
        start_load = os.getloadavg()
        samples = {mode: [] for mode in modes}
        output = None
        for pair in range(args.pairs):
            order = modes if pair % 2 == 0 else modes[::-1]
            for mode in order:
                start = time.perf_counter()
                result = run(['taskset', '-c', str(args.cpu), hl, str(bytecode),
                              pattern, str(args.iterations)], dict(env, HL_JIT_REGOPT=str(mode)))
                samples[mode].append(time.perf_counter() - start)
                if output is not None and result.stdout != output:
                    raise RuntimeError(f'{pattern}: results differ between runs')
                output = result.stdout
        for mode in modes:
            stats_env = dict(env, HL_JIT_REGOPT=str(mode), HL_JIT_REGSTATS='2')
            stats = run([hl, str(bytecode), pattern, '1000'], stats_env)
            (work / f'{pattern}-{mode}.stats').write_text(stats.stderr)
            perf = subprocess.run(['taskset', '-c', str(args.cpu), 'perf', 'stat', '-e',
                                   'instructions,cycles', '--', hl, str(bytecode), pattern,
                                   str(args.iterations)], cwd=ROOT,
                                  env=dict(env, HL_JIT_REGOPT=str(mode)), capture_output=True, text=True)
            (work / f'{pattern}-{mode}.perf').write_text(perf.stdout + perf.stderr)
            if perf.returncode:
                print(f'perf unavailable for {pattern}/{mode}: see log', flush=True)
        medians = {mode: statistics.median(values) for mode, values in samples.items()}
        row = dict(pattern=pattern, iterations=args.iterations, cpu=args.cpu, samples=samples,
                   medians=medians, improvement=1 - medians[modes[1]] / medians[modes[0]],
                   load_before=start_load, load_after=os.getloadavg(), oracle_1000=oracle.strip())
        rows.append(row)
        (work / 'results.json').write_text(json.dumps(rows, indent=2))
        print(f'{pattern}: {medians}, improvement {row["improvement"]:.1%}', flush=True)


if __name__ == '__main__':
    main()
