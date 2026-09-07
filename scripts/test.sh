#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/vendor/hashlink/hl"
test_classpaths=(-cp src -cp tests -cp tests/compiler -cp tests/runtime -cp tests/tooling)

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

if [[ ${SKIP_FORMAT_CHECK:-0} != 1 ]]; then
	"$root_dir/scripts/format.sh" --check
fi

make -C "$root_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null
mkdir -p "$root_dir/out"
cc -shared -fPIC -DHL_NAME\(n\)=realtime_##n \
	-I "$root_dir/vendor/hashlink/src" \
	"$root_dir/native/runtime.c" \
	-L "$root_dir/vendor/hashlink" -lhl \
	-Wl,-rpath,"$root_dir/vendor/hashlink" \
	-o "$root_dir/out/realtime_runtime.hdll"

"$root_dir/tests/differential/run.sh"
"$haxe" --cwd "$root_dir" -cp tests --run driver.TestDriver --root "$root_dir"

# PosInfos produces two programs whose exit codes encode refreshed source lines.
pos_initial_output="$root_dir/out/pos-initial.hl"
pos_edited_output="$root_dir/out/pos-edited.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run PosInfosMain "$pos_initial_output" "$pos_edited_output"
for position_fixture in "$pos_initial_output:4" "$pos_edited_output:5"; do
	position_output=${position_fixture%:*}
	position_expected=${position_fixture##*:}
	set +e
	LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$position_output"
	position_status=$?
	set -e
	if [[ $position_status -ne $position_expected ]]; then
		echo "PosInfos: expected line $position_expected, got $position_status" >&2
		exit 1
	fi
done
echo "PASS: PosInfos call-site lines refresh after source edits"
