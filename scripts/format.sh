#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
formatter="$root_dir/.tools/formatter/run.js"

if [[ ! -f "$formatter" ]]; then
    echo "missing local formatter; run ./scripts/bootstrap-tools.sh first" >&2
    exit 1
fi

check=0
changed=0
for argument in "$@"; do
    case "$argument" in
        --check) check=1 ;;
        --changed) changed=1 ;;
        *) echo "usage: $0 [--check] [--changed]" >&2; exit 2 ;;
    esac
done

# Both formatter implementations use the compiler lexer. Never let the host tool
# write unchecked output, even when checking whether a file would change.
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-format.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
"$root_dir/.tools/haxe/haxe" --cwd "$root_dir" common.hxml -main tools.FormatterTokenGuard -js "$work/token-guard.js"
external_formatter=(node "$root_dir/scripts/format-external.js" "$work/token-guard.js")

if [[ $changed -eq 1 ]]; then
    # Until the one-shot reformat after the branches merge, a changed file must not become dirty: a file this branch adds must be clean, and a file
    # that was clean at the merge base with origin/main must still be. A file that was already unformatted at the base is left alone.
    base=$(git -C "$root_dir" merge-base HEAD origin/main)
    mapfile -t changed_files < <(cd "$root_dir" && git diff --name-only --diff-filter=d "$base" -- src tests benchmarks | rg '\.hx$' | sort)
    source_files=()
    if [[ ${#changed_files[@]} -gt 0 ]]; then
        base_dir="$work/base"
        mkdir -p "$base_dir"
        for relative in "${changed_files[@]}"; do
            if git -C "$root_dir" cat-file -e "$base:$relative" 2>/dev/null; then
                mkdir -p "$base_dir/$(dirname "$relative")"
                git -C "$root_dir" show "$base:$relative" > "$base_dir/$relative"
            fi
        done
        # Which of the base versions were clean, by the same formatters the check uses.
        mapfile -t base_files < <(cd "$base_dir" && rg --files -g '*.hx' 2>/dev/null | sort)
        dirty_at_base=()
        if [[ ${#base_files[@]} -gt 0 ]]; then
            base_arguments=()
            for relative in "${base_files[@]}"; do base_arguments+=("$base_dir/$relative"); done
            while IFS=$'\t' read -r profile base_file; do
                if [[ $profile == struct ]]; then
                    status=0
                    "$root_dir/scripts/haxeon" fmt --check "$base_file" >"$work/base.log" 2>&1 || status=$?
                else
                    status=0
                    "${external_formatter[@]}" -s "$base_file" --check >"$work/base.log" 2>&1 || status=$?
                fi
                if [[ $status -gt 1 ]]; then cat "$work/base.log" >&2; exit "$status"; fi
                [[ $status -eq 0 ]] || dirty_at_base+=("${base_file#"$base_dir/"}")
            done < <(node "$root_dir/scripts/format-source-profile.js" "${base_arguments[@]}")
        fi
        for relative in "${changed_files[@]}"; do
            skip=0
            for dirty in "${dirty_at_base[@]}"; do
                [[ $dirty == "$relative" ]] && skip=1
            done
            [[ $skip -eq 1 ]] || source_files+=("$root_dir/$relative")
        done
    fi
    if [[ ${#source_files[@]} -eq 0 ]]; then
        echo "format: every changed .hx file was already unformatted at the merge base with origin/main (or none changed)"
        exit 0
    fi
else
    mapfile -t source_files < <(rg --files "$root_dir/src" "$root_dir/tests" "$root_dir/benchmarks" -g '*.hx' | sort)
fi
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

if [[ $check -eq 1 ]]; then
    status=0
    if [[ ${#external_files[@]} -gt 0 ]]; then
        "${external_formatter[@]}" "${external_arguments[@]}" --check || status=$?
    fi
    if [[ ${#struct_files[@]} -gt 0 ]]; then
		struct_status=0
		"$struct_formatter" fmt --check "${struct_files[@]}" || struct_status=$?
		[[ $struct_status -le $status ]] || status=$struct_status
	fi
    exit "$status"
fi

for _ in 1 2 3; do
    "${external_formatter[@]}" "${external_arguments[@]}"
    check_status=0
    "${external_formatter[@]}" "${external_arguments[@]}" --check >"$work/stability.log" 2>&1 || check_status=$?
    if [[ $check_status -gt 1 ]]; then cat "$work/stability.log" >&2; exit "$check_status"; fi
    if [[ $check_status -eq 0 ]]; then
        break
    fi
done

if ! "${external_formatter[@]}" "${external_arguments[@]}" --check >/dev/null; then
	echo "formatter did not reach a stable result after three passes" >&2
	exit 1
fi
if [[ ${#struct_files[@]} -gt 0 ]]; then
	"$struct_formatter" fmt "${struct_files[@]}"
	"$struct_formatter" fmt --check "${struct_files[@]}"
fi
