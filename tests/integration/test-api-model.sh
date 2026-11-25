#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_dir"
compiler=${HAXEON_COMPILER_HL:-$(scripts/haxeon dev tool-path compiler.tools.HaxeonCompiler)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=tests/fixtures/api-model

compile() {
	scripts/hashlink-launch.sh hl "$compiler" --verbosity=quiet --entry=sample.Main --root="$root" \
		--output="$work/$1.hl" "$root/sample/Main.hx" "${@:2}"
}
compile plain
compile described --api-json="$work/api.json"
compile repeated --api-json "$work/repeat.json"
cmp "$work/plain.hl" "$work/described.hl"
cmp "$work/api.json" "$work/repeat.json"

# The fixture targets its own declarations. Standard-library changes have their own tests.
python3 - "$work" "$root/expected.json" <<'PY'
import difflib
import json
import pathlib
import sys

work, expected_path = map(pathlib.Path, sys.argv[1:])
plain = (work / "plain.hl.hli").read_bytes()
described = (work / "described.hl.hli").read_bytes()
# The header is followed by a fresh 16-byte module ID for each one-shot build.
assert plain[:4] == described[:4] and plain[20:] == described[20:], "runtime identity table changed"

actual_path = work / "api.json"
actual = json.loads(actual_path.read_text())
# The writer's own field order, which the schema fixes, is compared as it is: no re-sorting.
modules = [entry for entry in actual["modules"] if entry["path"] == "sample.Main"]
declarations = [entry for entry in actual["types"] if entry["module"] == "sample.Main"]
line = lambda entry: json.dumps(entry, ensure_ascii=False, separators=(",", ":"))
actual = ('{"version":' + str(actual["version"]) + ',"modules":[\n' + ",\n".join(map(line, modules))
          + '\n],"types":[\n' + ",\n".join(map(line, declarations)) + "\n]}\n")
expected = expected_path.read_text()
if actual != expected:
    sys.stderr.writelines(difflib.unified_diff(
        expected.splitlines(keepends=True), actual.splitlines(keepends=True),
        fromfile=str(expected_path), tofile=str(actual_path)))
    sys.exit(1)
PY
echo "PASS: API JSON matches the typed declaration fixture and preserves the compiled module"
