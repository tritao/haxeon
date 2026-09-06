#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
hl="$root_dir/vendor/hashlink/hl"
compiler="$root_dir/bootstrap/compiler.hl"
runtime="$root_dir/out/realtime_runtime.hdll"
report=${REPORT:-"$root_dir/out/diagnostics/bootstrap-crash.log"}

if [[ ! -x "$hl" || ! -f "$compiler" ]]; then
	echo "missing HashLink or bootstrap compiler; run ./scripts/bootstrap-compiler.sh first" >&2
	exit 1
fi
if ! command -v gdb >/dev/null 2>&1; then
	echo "gdb is required for bootstrap crash diagnostics" >&2
	exit 1
fi

mkdir -p "$(dirname "$report")" "$root_dir/out/bootstrap"
make -C "$root_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null
cc -shared -fPIC -DHL_NAME\(n\)=realtime_##n \
	-I "$root_dir/vendor/hashlink/src" "$root_dir/native/runtime.c" \
	-L "$root_dir/vendor/hashlink" -lhl -Wl,-rpath,"$root_dir/vendor/hashlink" -o "$runtime"

mapfile -t sources < <(cd "$root_dir" && find src stdlib -type f -name '*.hx' -print | LC_ALL=C sort)
command=("$hl" "$compiler" --output=out/bootstrap/compiler-diagnostic.hl \
	--entry=compiler.tools.BootstrapCompiler --root=src --root=stdlib "${sources[@]}")

{
	echo "bootstrap crash diagnostic"
	echo "timestamp: $(date --iso-8601=seconds)"
	echo "revision: $(git -C "$root_dir" rev-parse HEAD)"
	echo "hashlink: $($hl --version)"
	printf "command:"
	printf " %q" "${command[@]}"
	printf "\n\n"
} >"$report"

set +e
(
	cd "$root_dir"
	LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" \
		gdb -q -batch -ex "set pagination off" -ex run -ex "thread apply all bt 30" \
		-ex "info registers" --args "${command[@]}"
) >>"$report" 2>&1
gdb_status=$?
set -e

echo "bootstrap diagnostic report: $report"
if rg -q "received signal SIG(SEGV|ABRT|BUS|ILL)" "$report"; then
	rg -n "received signal|Program received|^#0 |^#1 |^#2 " "$report" | tail -n 80 || true
	exit 139
fi
tail -n 40 "$report"
exit "$gdb_status"
