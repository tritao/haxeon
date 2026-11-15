#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cli="$repo_dir/scripts/haxeon"
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-formatter.XXXXXX")
trap 'rm -rf -- "$project_dir"' EXIT

# The project's haxeon.json sets the style: two spaces and 40 columns here, so the wrapping below is visible.
printf '{"version": 1, "format": {"indent": "spaces", "indentWidth": 2, "lineWidth": 40}}\n' > "$project_dir/haxeon.json"
cd "$project_dir"

source='function main():Int { var value=compute(firstArgument,secondArgument,thirdArgument); return value; }'
formatted=$(printf '%s\n' "$source" | "$cli" fmt --stdin)
# An over-long argument list is filled: wrapped as late as it fits, one continuation level in.
[[ "$formatted" == *$'compute(firstArgument,\n'* ]]
[[ "$formatted" == *$'    secondArgument, thirdArgument);'* ]]

printf '%s\n' "$formatted" | "$cli" fmt --stdin --check

set +e
printf '%s\n' "$source" | "$cli" fmt --stdin --check >/dev/null
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
"$cli" fmt "$source_path"
"$cli" fmt --check "$source_path"

struct_path="$project_dir/Struct.hx"
printf 'struct Vec2 { public var x:Int; }\n' > "$struct_path"
"$cli" fmt "$struct_path"
grep -q '^struct Vec2 {' "$struct_path"
"$cli" fmt --check "$struct_path"

# A property path keeps its backslash: formatting once dropped it, which turned the path into a different name.
path_source=$(printf 'function main():Int { return Diff.bit(\\Style.width) | Diff.bit( \\Style.mode ); }')
path_formatted=$(printf '%s\n' "$path_source" | "$cli" fmt --stdin)
[[ "$path_formatted" == *'Diff.bit(\Style.width)'* && "$path_formatted" == *'Diff.bit(\Style.mode)'* ]]

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
"$cli" fmt "$tree_dir"
"$cli" fmt --check "$tree_dir"
"$cli" lint "$tree_dir" >/dev/null
set +e
"$cli" lint --manifest "$tree_dir" "$source_path" >/dev/null 2>&1
manifest_status=$?
set -e
if [[ $manifest_status -ne 1 ]]; then
	echo "expected lint to refuse a directory as a manifest, got $manifest_status" >&2
	exit 1
fi

# A nested haxeon.json without a "format" section (a package's tests) takes the enclosing project's setting.
mkdir -p "$project_dir/tests"
printf '{"version": 1}\n' > "$project_dir/tests/haxeon.json"
printf '%s\n' "$source" > "$project_dir/tests/Nested.hx"
"$cli" fmt "$project_dir/tests/Nested.hx"
cmp -s "$project_dir/tests/Nested.hx" "$source_path"

# With no setting above a file, the standard style applies: tabs and 120 columns.
plain_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-formatter-plain.XXXXXX")
trap 'rm -rf -- "$project_dir" "$plain_dir"' EXIT
printf 'class Plain {\nfunction f():Int {\nreturn 1;\n}\n}\n' > "$plain_dir/Plain.hx"
"$cli" fmt "$plain_dir/Plain.hx"
grep -q $'^\t\treturn 1;$' "$plain_dir/Plain.hx"

# A malformed setting is an error naming the manifest, never ignored, and the old flags are gone.
printf '{"version": 1, "format": {"indent": "wide"}}\n' > "$plain_dir/haxeon.json"
if "$cli" fmt --check "$plain_dir/Plain.hx" >/dev/null 2>"$plain_dir/error.txt" || ! grep -q 'format.indent' "$plain_dir/error.txt"; then
	echo "expected a malformed format setting to fail with its key" >&2
	exit 1
fi
if "$cli" fmt --line-width 40 "$source_path" >/dev/null 2>&1; then
	echo "expected --line-width to be refused: the project setting decides" >&2
	exit 1
fi

echo "PASS: built-in formatter CLI stdin, check, file, directory, struct and project-setting modes"
