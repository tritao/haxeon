#!/usr/bin/env bash
# The API model (docs/design/API_MODEL.md): a description of a fixture covering each declaration kind matches its expected
# JSON, is the same when written twice, and does not depend on an entry.
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_dir"
compiler=${HAXEON_COMPILER_HL:-$(scripts/haxeon dev tool-path compiler.tools.HaxeonCompiler)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=tests/fixtures/api-model

describe() {
	scripts/hashlink-launch.sh hl "$compiler" --verbosity=quiet --no-output --root="$root" --api-json="$work/$1.json" \
		"$root/sample/Main.hx" "$root/sample/internal/Detail.hx" "${@:2}"
}
describe entryless
describe repeated
describe entry --entry=sample.Main
cmp "$work/entryless.json" "$work/repeated.json"
cmp "$work/entryless.json" "$work/entry.json"

# The fixture checks its own declarations; the standard library's are not part of it.
python3 - "$work/entryless.json" "$root/expected.json" <<'PY'
import difflib
import json
import sys

actual_path, expected_path = sys.argv[1:]
actual = json.loads(open(actual_path).read())
# The writer's own field order, which the schema fixes, is compared as it is: no re-sorting.
described = [path for path in actual["described"] if path.startswith("sample.")]
# A package named internal is a package like any other: what a package keeps to itself is written `internal`.
assert described == ["sample.Main", "sample.internal.Detail"], described
assert any(entry["path"] == "sample.internal.Detail" for entry in actual["types"]), "the referenced type is missing"
modules = [entry for entry in actual["modules"] if entry["path"] == "sample.Main"]
declarations = [entry for entry in actual["types"] if entry["module"] == "sample.Main"]
line = lambda entry: json.dumps(entry, ensure_ascii=False, separators=(",", ":"))
actual = ('{"version":' + str(actual["version"]) + ',"described":' + json.dumps(described, separators=(",", ":"))
          + ',"modules":[\n' + ",\n".join(map(line, modules))
          + '\n],"types":[\n' + ",\n".join(map(line, declarations)) + "\n]}\n")
expected = open(expected_path).read()
if actual != expected:
    sys.stderr.writelines(difflib.unified_diff(
        expected.splitlines(keepends=True), actual.splitlines(keepends=True),
        fromfile=expected_path, tofile=actual_path))
    sys.exit(1)
PY
echo "PASS: the API description matches the fixture, is deterministic, and is the same with or without an entry"
