# Register allocator microbenchmarks

These programs are opt-in and are not registered in the normal test suite.
`RegallocBench` isolates six patterns: no-call float accumulation, a real hot
call, a rare returning call, seven live integer accumulators across a call,
nested loops using an outer value, and a two-way loop-carried update.

Build the stock-Haxe seed compiler, then run paired measurements:

```sh
export LD_LIBRARY_PATH=$PWD/out:$PWD/.tools/hashlink
mkdir -p out/regalloc
.tools/haxe/haxe --cwd . -cp src -hl out/regalloc/compiler.hl -main compiler.tools.HaxeonCompiler
python3 tests/bench/jit-regalloc/run.py --modes 0,4
```

The runner disables Haxeon's inliner when compiling the micros, checks all small
results against stock Haxe Eval, pins CPU 0, waits for load <= 4, and runs nine
alternating pairs. Each result records load, time, static JIT counts, and retired
instructions/cycles from `perf stat`. `--modes` selects two allocator masks;
`--allow-busy` is for diagnostics, not acceptance measurements.

Disassemble after GDB's JIT registration notification, before executing the loop:

```sh
gdb -batch \
  -ex 'set pagination off' -ex 'tty /dev/null' \
  -ex 'break __jit_debug_register_code' \
  -ex 'run out/regalloc/micro-results/micro.hl cold 1000' \
  -ex 'finish' -ex "disassemble 'RegallocBench.cold'" \
  .tools/hashlink/hl
```

For A/B disassembly add `-ex 'set environment HL_JIT_REGOPT 4'`. Stopping at
registration avoids sampling different loop iterations and includes complete
machine code for the function. Expected results at 1,000 iterations:

| Pattern | Stock Haxe Eval result |
| --- | ---: |
| baseline | 437.5 |
| hot | 437.5 |
| cold | 437.625 |
| pressure | 14028 |
| nested | 527500 |
| conditional | 187.5 |

The integer-pressure workload intentionally uses Haxe's wrapping Int arithmetic;
no Float-to-Int conversion is needed. Large counts can wrap the final checksum.
