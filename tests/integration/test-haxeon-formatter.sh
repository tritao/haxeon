#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cli="$repo_dir/scripts/haxeon"
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-formatter.XXXXXX")
trap 'rm -rf -- "$project_dir"' EXIT

node - "$repo_dir" <<'JS'
const assert = require('assert');
const fs = require('fs');
const {hasStructDeclaration} = require(process.argv[2] + '/scripts/format-source-profile.js');
for (const source of [
  'struct Vec2 { public var x:Int; }',
  '@:value struct /* comment */ Vec2 { public var x:Int; }',
  '/* struct Fake {} */ struct Real {}'
]) assert.strictEqual(hasStructDeclaration(source), true, source);
for (const source of [
  'class Main { var text = "\nstruct Fake {}"; }',
  "class Main { var text = '\nstruct Fake {}'; }",
  '// struct Fake {}\nclass Main {}',
  '/* struct Fake {} */ class Main {}',
  'class Main { var pattern = ~/struct Fake [/] {}/; }',
  "class Main { var text = '${'struct Fake {}'}'; }"
]) assert.strictEqual(hasStructDeclaration(source), false, source);
assert.strictEqual(hasStructDeclaration(fs.readFileSync(process.argv[2] + '/tests/runtime/HxiNumericStorageMain.hx', 'utf8')), false);
console.log('PASS: formatter profiles ignore embedded structs in literals/comments/regex/interpolation');
JS

source='function main():Int { var value=compute(firstArgument,secondArgument,thirdArgument); return value; }'
formatted=$(printf '%s\n' "$source" | "$cli" fmt --stdin --line-width 40)
[[ "$formatted" == *$'compute(\n'* ]]
[[ "$formatted" == *$'    firstArgument,'* ]]

printf '%s\n' "$formatted" | "$cli" fmt --stdin --line-width 40 --check

set +e
printf '%s\n' "$source" | "$cli" fmt --stdin --line-width 40 --check >/dev/null
check_status=$?
set -e
if [[ $check_status -ne 1 ]]; then
	echo "expected fmt --check to reject unformatted stdin, got $check_status" >&2
	exit 1
fi

source_path="$project_dir/Main.hx"
printf '%s\n' "$source" > "$source_path"
set +e
"$cli" fmt --check "$source_path" >/dev/null
file_check_status=$?
set -e
if [[ $file_check_status -ne 1 ]]; then
	echo "expected fmt --check to reject an unformatted file, got $file_check_status" >&2
	exit 1
fi
"$cli" fmt --line-width 40 "$source_path"
"$cli" fmt --line-width 40 --check "$source_path"

struct_path="$project_dir/Struct.hx"
printf 'struct Vec2 { public var x:Int; }\n' > "$struct_path"
"$cli" fmt "$struct_path"
grep -q '^struct Vec2 {' "$struct_path"
"$cli" fmt --check "$struct_path"

# A directory stands for the .hx files under it; reading one as a file used to crash HashLink.
tree_dir="$project_dir/tree"
mkdir -p "$tree_dir/nested"
printf '%s\n' "$source" > "$tree_dir/nested/Deep.hx"
printf 'not haxe\n' > "$tree_dir/notes.txt"
set +e
"$cli" fmt --check "$tree_dir" >/dev/null
directory_check_status=$?
set -e
if [[ $directory_check_status -ne 1 ]]; then
	echo "expected fmt --check to reject an unformatted file under a directory, got $directory_check_status" >&2
	exit 1
fi
"$cli" fmt --line-width 40 "$tree_dir"
"$cli" fmt --line-width 40 --check "$tree_dir"
"$cli" lint "$tree_dir" >/dev/null
set +e
"$cli" lint --manifest "$tree_dir" "$source_path" >/dev/null 2>&1
manifest_status=$?
set -e
if [[ $manifest_status -ne 1 ]]; then
	echo "expected lint to refuse a directory as a manifest, got $manifest_status" >&2
	exit 1
fi

echo "PASS: built-in formatter CLI stdin, check, file, directory, and struct modes"
