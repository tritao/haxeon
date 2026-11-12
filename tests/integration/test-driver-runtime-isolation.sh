#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/../.." && pwd)
if [[ $(uname -s) != Linux ]]; then
  echo 'SKIP: mapped-library integration requires Linux /proc'
  exit 0
fi
hashlink_dir=$("$root_dir/scripts/hashlink-path.sh")
# The driver names the output directory as given but reports a loaded library by its real path; `out` may be a symlink to another disk.
out_dir=$(realpath "$root_dir/out")
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-runtime-isolation.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/out" "$work/loaded" "$work/bin"
cp "$root_dir/out/haxeon_runtime.hdll" "$work/out/haxeon_runtime.hdll"
cp "$root_dir/out/haxeon_runtime.hdll" "$work/loaded/haxeon_runtime.hdll"
printf 'int rebuilt_runtime(void) { return 42; }\n' > "$work/runtime.c"
"$root_dir/.tools/haxe/haxe" --cwd "$root_dir" common.hxml -cp tests/runtime -hl "$work/probe.hl" -main RuntimeBuildSafetyProbe
"$root_dir/.tools/haxe/haxe" --cwd "$root_dir" common.hxml -hl "$work/driver.hl" -main build.HaxeonBuild

# An accidental failure to detect the mapping must never launch a real native build.
cat > "$work/bin/cmake" <<'CMOCK'
#!/usr/bin/env bash
printf 'native build marker\n' >&2
exit 97
CMOCK
chmod +x "$work/bin/cmake"
set +e
(cd "$root_dir" && PATH="$work/bin:$PATH" LD_LIBRARY_PATH="$root_dir/out:$hashlink_dir" \
  "$hashlink_dir/hl" "$work/driver.hl" test 1) > "$work/refusal.log" 2>&1
status=$?
set -e
if [[ $status != 1 ]] || ! grep -Fq "Cannot build native libraries in $root_dir/out:" "$work/refusal.log" \
    || ! grep -Fq "$out_dir/haxeon_runtime.hdll" "$work/refusal.log" \
    || grep -Fq 'native build marker' "$work/refusal.log"; then
  cat "$work/refusal.log" >&2
  echo "FAIL: driver did not reject its loaded runtime (exit $status)" >&2
  exit 1
fi
# A separately loaded runtime is still unsafe if the running VM uses libhl
# from the other directory that the release native build writes to.
set +e
(cd "$root_dir" && PATH="$work/bin:$PATH" LD_LIBRARY_PATH="$work/loaded:$root_dir/out/cmake/release/hashlink-runtime" \
  "$root_dir/out/cmake/release/hashlink-runtime/hl" "$work/driver.hl" test 1) > "$work/toolchain-refusal.log" 2>&1
status=$?
set -e
if [[ $status != 1 ]] || ! grep -Fq "Cannot build native libraries in $root_dir/out/cmake/release/hashlink-runtime:" "$work/toolchain-refusal.log" \
    || ! grep -Fq 'libhl.so' "$work/toolchain-refusal.log" \
    || grep -Fq 'native build marker' "$work/toolchain-refusal.log"; then
  cat "$work/toolchain-refusal.log" >&2
  echo "FAIL: driver did not reject its loaded HashLink library (exit $status)" >&2
  exit 1
fi
# With both the runtime and VM library isolated, the guard lets the build run.
cp "$hashlink_dir/hl" "$work/loaded/hl"
cp -L "$hashlink_dir/libhl.so.1" "$work/loaded/libhl.so.1"
set +e
(cd "$root_dir" && PATH="$work/bin:$PATH" LD_LIBRARY_PATH="$work/loaded" \
  "$work/loaded/hl" "$work/driver.hl" test 1) > "$work/allowed.log" 2>&1
status=$?
set -e
if [[ $status != 97 ]] || ! grep -Fq 'native build marker' "$work/allowed.log"; then
  cat "$work/allowed.log" >&2
  echo "FAIL: isolated driver did not reach the native build (exit $status)" >&2
  exit 1
fi
LD_LIBRARY_PATH="$work/out:$hashlink_dir" "$hashlink_dir/hl" "$work/probe.hl" "$work/out" conflict "$work/runtime.c"
ln -s "$work/out" "$work/output-link"
LD_LIBRARY_PATH="$work/out:$hashlink_dir" "$hashlink_dir/hl" "$work/probe.hl" "$work/output-link" conflict "$work/runtime.c"
mkdir -p "$work/hard link"
ln "$work/out/haxeon_runtime.hdll" "$work/hard link/haxeon_runtime.hdll"
LD_LIBRARY_PATH="$work/hard link:$hashlink_dir" "$hashlink_dir/hl" "$work/probe.hl" "$work/out" conflict "$work/runtime.c"
df -h /
LD_LIBRARY_PATH="$work/loaded:$hashlink_dir" "$hashlink_dir/hl" "$work/probe.hl" "$work/out" safe "$work/runtime.c"
echo 'PASS: driver rejects a mapped build output and permits a separate native rebuild'
