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
an HLPC capture (default `build/host/profile/profile-<timestamp>/profile.hlpc`), and prints
a top-functions report after the process exits. Pass `--profile-output PATH` to
choose the capture location, and runtime arguments after `--`:

```sh
haxeon run --profile --profile-output build/host/profile/editor.hlpc
```

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

Profile captures include `capture.json` and a copy of the exact bytecode used
by the run. A HashLink heap dump captured by the application can be placed in
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

