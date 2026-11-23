#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*) echo 'SKIP: shell stub launcher regression requires Unix'; exit 0 ;;
esac
# The launchers name paths as `cd … && pwd` does, so spell $work the same way: macOS's TMPDIR ends in a slash.
work=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/haxeon-vm-launchers.XXXXXX")" && pwd)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/scripts" "$work/cmake" "$work/out/sdk/bin"
cp "$root/scripts/hl" "$root/scripts/hlprof-live" "$root/scripts/hashlink-launch.sh" "$root/scripts/hashlink-path.sh" "$work/scripts/"
cp "$root/cmake/hashlink-output-paths.txt" "$work/cmake/"
for program in hl hlprof-live; do
	set +e
	"$work/scripts/$program" > "$work/missing.log" 2>&1
	status=$?
	set -e
	if [[ $status != 1 ]] || ! grep -Fq "Missing checkout-built HashLink program: $work/out/sdk/bin/$program" "$work/missing.log"; then
		cat "$work/missing.log" >&2
		echo "FAIL: missing $program did not produce a clear error (exit $status)" >&2
		exit 1
	fi
done
cat > "$work/out/sdk/bin/hl" <<'PROGRAM'
#!/usr/bin/env bash
printf '%s\n' "$LD_LIBRARY_PATH" "$DYLD_LIBRARY_PATH" "$@"
exit 42
PROGRAM
chmod +x "$work/out/sdk/bin/hl"
cp "$work/out/sdk/bin/hl" "$work/out/sdk/bin/hlprof-live"
for program in hl hlprof-live; do
	set +e
	LD_LIBRARY_PATH=existing DYLD_LIBRARY_PATH=existing "$work/scripts/$program" 'argument with spaces' > "$work/$program.log"
	status=$?
	set -e
	first=$(sed -n '1p' "$work/$program.log")
	second=$(sed -n '2p' "$work/$program.log")
	third=$(sed -n '3p' "$work/$program.log")
	expected="$work/out:$work/out/sdk/bin:existing"
	if [[ $status != 42 || $first != "$expected" || $second != "$expected" || $third != "argument with spaces" ]]; then
		cat "$work/$program.log" >&2
		echo "FAIL: $program did not preserve its library paths, argument, or exit status ($status)" >&2
		exit 1
	fi
done
echo 'PASS: checkout VM and profiler launchers preserve paths, arguments, and status'
