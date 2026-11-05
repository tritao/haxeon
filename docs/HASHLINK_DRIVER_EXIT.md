# HashLink test-driver exit

A test driver printed a zero-failure summary, then exited with SIGSEGV. Its
native backtrace ran through `hl_sys_exit`, `exit`, `_dl_fini`, and
`_dl_call_fini` while finalizing `out/haxeon_runtime.hdll`. A build wrapper had
overwritten that loaded runtime in place; reproducing that overwrite produced
the same backtrace.

Before building native code, the HashLink test driver now refuses to run when
either `out` or the checkout-local HashLink build directory contains or aliases a
library it has loaded. Linux checks actual process mappings; other platforms
conservatively check native library search paths. Start the driver with separate
copies of the VM, `libhl`, and runtime by running `scripts/test-driver.sh 8`.
The launcher copies the checkout-built VM and libraries; run
`scripts/build-native.sh` first. The build and running process then use
different files, and exit statuses are preserved.

Content-addressed native outputs are future work. `ArtifactCache` is keyed by
build actions, restores into mutable paths, and excludes delegated CMake
builds; immutable library identities would also require loader, launcher, and
retention changes.

Run compiled programs with `scripts/hl` and the profiler with
`scripts/hlprof-live`; both require `scripts/build-native.sh` first.

The self-hosted UI Showcase compiler also runs through `scripts/hl`, so its
`haxeon_runtime.hdll` dependency is found without an inherited library path.
The Wasm gate includes a fresh self-hosted `packages/ui/tools/build-web.sh` build
with `NKUI_HAXEON_TARGET=wasm-gc`, followed by the Showcase scene pairs, and the
Wasm32 browser smoke. The six UI value snapshots remain in
`scripts/test-wasm-gc-parity.sh`. Integration gates and the paired editor census,
RSS windows and per-action KiB are recorded in
[UI value types](../packages/ui/docs/VALUE_TYPES.md#checkout-vm-launcher-integration).
