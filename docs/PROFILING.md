# Profiling

Profiling workflows for compiler and host applications.

For short-lived compiler profiling runs, start the HashLink process with
`--diagnostics-wait`. It opens the diagnostics socket, holds the program before
its entrypoint, and resumes after `hlprof-live` configures sampling. Run the
first command in one terminal and the second in another:

```sh
LD_LIBRARY_PATH="$PWD/out:$PWD/.tools/hashlink" \
  .tools/hashlink/hl --diagnostics 24020 --diagnostics-wait out/compiler.hl
.tools/hashlink/hlprof-live --connect-timeout 10 --rate 500 --output out/compiler.hlpc 24020
```

For host applications, `haxeon run --profile` automates that handshake: it builds
the project, launches it with `--diagnostics-wait`, attaches `hlprof-live`, writes
an HLPC capture (default `build/host/profile/profile-<timestamp>/profile.hlpc`),
exports it as a native Perfetto trace (`profile.pftrace` next to the capture), and
prints a top-functions report after the process exits. Open the `.pftrace` at
https://ui.perfetto.dev. Pass `--profile-output PATH` to choose the capture
location, and runtime arguments after `--`:

```sh
haxeon run --profile --profile-output build/host/profile/editor.hlpc
```

`--profile` also works with `--watch` and `--watch --live`. Each launch of the
watched app gets its own capture directory under the profile root (or under
`--profile-output`, which is then a directory), finished when that launch exits
or is relaunched after an edit. Live patches stay inside one capture: the trace
shows a `live.patch` (or `live.reload`) slice at the patch, a "module loaded" or
"module revision" instant, and JIT frames named `[hashlink-jit m<module> r<revision>]`,
so samples before and after a patch are attributed to the code that actually ran.
In exosuit, `python scripts/run.py [--watch|--live] --profile` forwards the flag.

### What a trace contains

- Stack samples (`--rate`, default 1000 Hz from `haxeon run`) with Haxe frames
  named `Class.method` with file and line.
- Mixed-mode stacks on Windows x64: samples walk through native code with the
  unwind data of each module and of the JIT, so a stack shows Haxe calling into
  a native library and back into Haxe callbacks. A native frame belongs to its
  module's mapping and is named by its function, with file and line when the
  module has a PDB. Without a PDB it is named after the nearest export,
  `module!export+0x...`, and an address outside every known module is named
  `[unknown 0x...]`. Other platforms record Haxe frames and stop at the first
  native frame.
- Span slices from `haxeon.ProfileSpan`, on the thread that emitted them.
- Counters: HashLink GC counters, plus app counters from
  `haxeon.ProfileCounter.set(name, value)`.
- Instants for module loads and live module revisions.

The desktop UI host marks each pump step's event wait and dispatch with
`ui.events`, which contains the `ui.frame` of any frame the events trigger.
`ui.frame` contains `ui.prepare`, `ui.submit`, `ui.render` and `ui.frame.gc`.
The exosuit editor also records the `ui.frame.allocated_bytes` counter. `ProfileSpan` and
`ProfileCounter` skip their work when nothing is recording, so they can stay in
shipped code.

MSVC Release builds of HashLink and the Haxeon runtime write PDBs next to the
binaries so the profiler and debuggers can name their functions.

To check a trace without opening the UI, `scripts/check-pftrace.py` runs
queries through Perfetto's `trace_processor_shell` (download it from the
Perfetto releases):

```sh
python3 scripts/check-pftrace.py --tp trace_processor_shell \
  --expect-process Main --expect-thread main --expect-slice ui.frame \
  --expect-counter ui.frame.allocated_bytes --min-samples 1000 \
  build/host/profile/profile-<timestamp>/profile.pftrace
```

On Windows x64, add `--expect-mixed` to require stacks that pass from Haxe
through native code and back into Haxe; other platforms do not record them.

Applications can mark a measured operation with `haxeon.ProfileSpan.begin(name)`
and `haxeon.ProfileSpan.end(name)`. Markers use the same clock and thread IDs as
the stack samples. Names may be UTF-8 text; begin/end names must match on each
thread. After exporting the capture, `scripts/hlprof-spans.py` lists the
slowest spans and the sampled leaf functions inside each one:

```sh
.tools/hashlink/hlprof-live export --format perfetto \
  --output out/editor.perfetto.json out/editor.hlpc
python3 scripts/hlprof-spans.py --min-ms 20 --top 20 \
  --output out/span-spikes.json out/editor.perfetto.json
```

The report includes sample counts, dropped-record counts, and incomplete span
counts when capture ends before the final marker is drained. A span with few
samples needs further investigation; sampling alone cannot prove whether its
thread was descheduled or blocked.

Profile captures include `capture.json` and a copy of the bytecode the run
was launched with, taken before launch. A live run also keeps each build it
patched or reloaded into, as `profile.r2.hl`, `profile.r3.hl` and so on, listed
under `liveRevisions` in the manifest. A capture directory holds one capture:
the trace and bytecode are named after the `.hlpc` file, and recording into a
directory that holds a different capture is refused. A HashLink heap dump captured by the application can be placed in
the same directory and added as the `heap` artifact in the manifest. Inspect
it with `haxeon heap inspect --capture DIR`, or pass the bytecode and dump paths
directly with `haxeon heap inspect BYTECODE DUMP`.

To profile incremental compiler edits, pass `--profile-output` to the project
benchmark. It starts a dedicated worker with a diagnostics port, warms that
worker before attaching, and captures the edit loop. The normal worker launch
is unchanged. Sampling adds overhead, so use an unprofiled run for latency
comparisons. HashLink's allocation samples currently identify the native
allocator rather than Haxe allocation call sites; the compiler's per-phase
allocation counters remain the better source for allocation totals.

```sh
python3 scripts/benchmark-incremental-project.py \
  --project /path/to/haxeon.json --source /path/to/Main.hx \
  --token-a 'before' --token-b 'after' --output /tmp/edit.hl \
  --profile-output /tmp/compiler-edits.hlpc
.tools/hashlink/hlprof-live export --format perfetto \
  --output /tmp/compiler-edits.json /tmp/compiler-edits.hlpc
```

Incremental benchmark output also reports `alloc-<phase>-bytes`, `-count`,
`-gcs`, and `-gc-ms` from HashLink's cumulative GC counters. These are
phase deltas; `gc-ms` measures stop-the-world marking. The `driver-alloc-*`
values cover request preparation, compilation, artifact encoding, and writing.
Use the unprofiled benchmark for latency comparisons, since live sampling adds
CPU overhead.

To see why an incremental edit recompiled what it did, run the build with `HAXEON_EXPLAIN_INVALIDATION=1`. The compiler worker
then writes, for each compile, how many artifacts each kind of invalidation selected (`source-revision`, `body-changed`,
`signature-changed`, `dependency-signature`, `purity-dependency`, ...), a sample of the artifacts with their causes, and how many
functions were retyped and regenerated, to its log under the session directory (`HAXEON_COMPILER_SESSION_DIR`, default
`~/.cache/haxeon/compiler`). A comment-only edit should retype nothing; if it reports a long list, the kind with the large count
names the dependency that is invalidating too much.

