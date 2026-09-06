#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$repo_dir/out"

make -C "$repo_dir/vendor/hashlink" -j2 libhl.so hl

cc -shared -fPIC -DHL_NAME\(n\)=realtime_\#\#n \
  -I "$repo_dir/vendor/hashlink/src" \
  "$repo_dir/native/runtime.c" \
  -L "$repo_dir/vendor/hashlink" -lhl \
  -Wl,-rpath,"$repo_dir/vendor/hashlink" \
  -o "$repo_dir/out/realtime_runtime.hdll"

"$repo_dir/.tools/haxe/haxe" "$repo_dir/dap-hot-reload-probe.hxml"

(
  cd "$repo_dir/out"
  LD_LIBRARY_PATH="$repo_dir/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    python3 "$repo_dir/scripts/hld3-harness.py" dap-hot-reload-probe.hl --hl "$repo_dir/vendor/hashlink/hl" --timeout 20
)
