#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
formatter="$root_dir/.tools/formatter/run.js"

if [[ ! -f "$formatter" ]]; then
    echo "missing local formatter; run ./scripts/bootstrap-tools.sh first" >&2
    exit 1
fi

mapfile -t source_files < <(rg --files "$root_dir/src" "$root_dir/tests" "$root_dir/benchmarks" -g '*.hx' | sort)
external_files=()
struct_files=()
profiles=$(node "$root_dir/scripts/format-source-profile.js" "${source_files[@]}")
while IFS=$'\t' read -r profile source_file; do
	if [[ $profile == struct ]]; then
		struct_files+=("$source_file")
	else
		external_files+=("$source_file")
	fi
done <<< "$profiles"

external_arguments=()
for source_file in "${external_files[@]}"; do
	external_arguments+=(-s "$source_file")
done
struct_formatter="$root_dir/scripts/haxeon"

if [[ ${1:-} == "--check" ]]; then
    node "$formatter" "${external_arguments[@]}" --check
    if [[ ${#struct_files[@]} -gt 0 ]]; then
		"$struct_formatter" fmt --check "${struct_files[@]}"
	fi
    exit
elif [[ $# -ne 0 ]]; then
    echo "usage: $0 [--check]" >&2
    exit 2
fi

for _ in 1 2 3; do
    node "$formatter" "${external_arguments[@]}"
    if node "$formatter" "${external_arguments[@]}" --check >/dev/null; then
        break
    fi
done

if ! node "$formatter" "${external_arguments[@]}" --check >/dev/null; then
	echo "formatter did not reach a stable result after three passes" >&2
	exit 1
fi
if [[ ${#struct_files[@]} -gt 0 ]]; then
	"$struct_formatter" fmt "${struct_files[@]}"
	"$struct_formatter" fmt --check "${struct_files[@]}"
fi
