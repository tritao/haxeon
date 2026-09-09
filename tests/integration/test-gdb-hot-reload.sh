#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
hashlink_dir="$repo_dir/.tools/hashlink"
gdb_commands="$(mktemp "${TMPDIR:-/tmp}/hashlink-gdb-patch.XXXXXX")"
gdb_output="$(mktemp "${TMPDIR:-/tmp}/hashlink-gdb-patch-output.XXXXXX")"
symbol_commands="$(mktemp "${TMPDIR:-/tmp}/hashlink-gdb-patch-symbols.XXXXXX")"
symbol_output="$(mktemp "${TMPDIR:-/tmp}/hashlink-gdb-patch-symbol-output.XXXXXX")"
core_file="$(mktemp "${TMPDIR:-/tmp}/hashlink-gdb-patch-core.XXXXXX")"
core_output="$(mktemp "${TMPDIR:-/tmp}/hashlink-gdb-patch-core-output.XXXXXX")"
rm -f "$core_file"
trap 'rm -f "$gdb_commands" "$gdb_output" "$symbol_commands" "$symbol_output" "$core_file" "$core_output"' EXIT

"$repo_dir/tests/integration/test-hot-reload.sh" >/dev/null
"$repo_dir/.tools/haxe/haxe" "$repo_dir/tests/hxml/static-field-test.hxml"
cc -shared -fPIC \
  -I "$repo_dir/vendor/hashlink/src" \
  "$repo_dir/tests/native/patch_core.c" \
  -L "$hashlink_dir" -lhl \
  -Wl,-rpath,"$hashlink_dir" \
  -o "$repo_dir/out/patch_core.hdll"
"$repo_dir/.tools/haxe/haxe" "$repo_dir/tests/hxml/gdb-patch-core-test.hxml"

cat > "$gdb_commands" <<'GDB'
set pagination off
break __jit_debug_register_code
commands
  silent
  set $action = *(unsigned int *)((char *)&__jit_debug_descriptor + 4)
  printf "JIT_EVENT=%u\n", $action
  continue
end
run hot-reload-test.hl
GDB

(
  cd "$repo_dir/out"
  LD_LIBRARY_PATH="$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    gdb -q -batch -x "$gdb_commands" "$hashlink_dir/hl"
) > "$gdb_output" 2>&1

registrations="$(grep -c 'JIT_EVENT=1' "$gdb_output" || true)"
unregistrations="$(grep -c 'JIT_EVENT=2' "$gdb_output" || true)"
if (( registrations < 2 || unregistrations < 1 )); then
  echo "GDB did not observe hot-patch JIT metadata lifecycle events" >&2
  cat "$gdb_output" >&2
  exit 1
fi

grep -F 'PASS: selective HLP patches are atomic and retain bounded JIT code' "$gdb_output" >/dev/null

cat > "$symbol_commands" <<'GDB'
set pagination off
break hl_gdb_jit_register_patch
run static-field-test.hl
finish
info line Main.hx:1
GDB

(
  cd "$repo_dir/out"
  LD_LIBRARY_PATH="$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    gdb -q -batch -x "$symbol_commands" "$hashlink_dir/hl"
) > "$symbol_output" 2>&1 || {
  echo "GDB could not inspect the first hot-patch registration" >&2
  cat "$symbol_output" >&2
  exit 1
}

grep -F 'Line 1 of "Main.hx" starts at address ' "$symbol_output" >/dev/null \
  && grep -F '<Counter.bump+' "$symbol_output" >/dev/null || {
  echo "GDB did not resolve the first hot-patch symbol and source line" >&2
  cat "$symbol_output" >&2
  exit 1
}

(
  cd "$repo_dir/out"
  LD_LIBRARY_PATH="$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    gdb -q -batch \
      -ex "run gdb-patch-core-test.hl" \
      -ex "generate-core-file $core_file" \
      "$hashlink_dir/hl"
) >/dev/null 2>&1

(
  cd "$repo_dir/out"
  LD_LIBRARY_PATH="$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    gdb -q -batch "$hashlink_dir/hl" "$core_file" \
      -ex "backtrace 6" \
      -ex "info line CrashPoint.hx:9"
) > "$core_output" 2>&1

grep -F 'in patch_core_fault ()' "$core_output" >/dev/null \
  && grep -F 'in CrashPoint.run () at CrashPoint.hx:17' "$core_output" >/dev/null \
  && grep -F 'Line 9 of "CrashPoint.hx"' "$core_output" >/dev/null \
  && grep -F 'but contains no code.' "$core_output" >/dev/null || {
  echo "A fresh GDB process could not symbolize the hot-patched core" >&2
  cat "$core_output" >&2
  exit 1
}

echo "PASS: GDB retained only the active patch in offline cores across $registrations registrations and $unregistrations unregistrations"
