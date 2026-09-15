#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cli="$repo_dir/scripts/haxeon"
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-formatter.XXXXXX")
trap 'rm -rf -- "$project_dir"' EXIT

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

echo "PASS: built-in formatter CLI stdin, check, and file modes"
