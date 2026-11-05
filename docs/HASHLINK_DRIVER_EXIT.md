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
