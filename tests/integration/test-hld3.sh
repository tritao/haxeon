#!/usr/bin/env bash
# HLD3, the checkout-built HashLink's debugger protocol: the handshake, and the patch-JIT mappings a live patch refreshes
# (tests/integration/hld3-harness.py drives tests/hxml/dap-hot-reload-probe.hxml under `hl --debug`).
set -euo pipefail

source "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/env.sh"
haxeon_require_haxe
haxeon_require_hashlink
haxeon_export_library_path
out="$haxeon_suite_out/hld3"
mkdir -p "$out"
"$haxeon_haxe" --cwd "$haxeon_root" tests/hxml/dap-hot-reload-probe.hxml -hl "$out/dap-hot-reload-probe.hl"
cd "$out"
python3 "$haxeon_root/tests/integration/hld3-harness.py" dap-hot-reload-probe.hl \
	--hl "$("$haxeon_root/scripts/hashlink-path.sh")/hl" --timeout 20
