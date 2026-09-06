#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/vendor/hashlink/hl"
runtime="$root_dir/out/realtime_runtime.hdll"
compiler_a="$root_dir/bootstrap/compiler.hl"
compiler_b="$root_dir/out/bootstrap/compiler-b.hl"
self_compiler="$root_dir/out/bootstrap/compiler-self.hl"

mode=${1:-bootstrap}
if [[ $# -gt 1 || "$mode" != "bootstrap" && "$mode" != "--self" ]]; then
	echo "usage: $0 [--self]" >&2
	exit 2
fi

if [[ ! -x "$hl" ]]; then
	echo "missing pinned HashLink executable; initialize and build vendor/hashlink" >&2
	exit 1
fi
if [[ "$mode" == "bootstrap" && ! -x "$haxe" ]]; then
	echo "missing reference Haxe compiler; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi
if [[ "$mode" == "--self" && ! -f "$compiler_a" ]]; then
	echo "missing bootstrap/compiler.hl" >&2
	exit 1
fi

mkdir -p "$root_dir/bootstrap" "$root_dir/out/bootstrap"
make -C "$root_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null
cc -shared -fPIC -DHL_NAME\(n\)=realtime_##n \
	-I "$root_dir/vendor/hashlink/src" \
	"$root_dir/native/runtime.c" \
	-L "$root_dir/vendor/hashlink" -lhl \
	-Wl,-rpath,"$root_dir/vendor/hashlink" \
	-o "$runtime"

mapfile -t sources < <(cd "$root_dir" && find src -type f -name '*.hx' -print | LC_ALL=C sort)

if [[ "$mode" == "--self" ]]; then
	(
		cd "$root_dir"
		LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$compiler_a" \
			--output=out/bootstrap/compiler-self.hl --entry=compiler.tools.BootstrapCompiler --root=src "${sources[@]}"
	)
	cmp "$compiler_a" "$self_compiler"
	echo "PASS: checked-in compiler rebuilt itself identically"
	exit 0
fi

"$haxe" --cwd "$root_dir" -cp src --run compiler.tools.BootstrapCompiler \
	--output=bootstrap/compiler.hl --entry=compiler.tools.BootstrapCompiler --root=src "${sources[@]}"

(
	cd "$root_dir"
	LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$compiler_a" \
		--output=out/bootstrap/compiler-b.hl --entry=compiler.tools.BootstrapCompiler --root=src "${sources[@]}"
)

cmp "$compiler_a" "$compiler_b"
echo "PASS: bootstrap compiler rebuilt an identical compiler"
