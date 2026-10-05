#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
home=${HAXEON_HOME:-$repo_dir}
haxe=${HAXEON_HAXE:-"$home/.tools/haxe/haxe"}
workspace_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-shards.XXXXXX")
source_cache=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-shards-cache.XXXXXX")
trap 'rm -rf -- "$workspace_dir" "$source_cache"' EXIT

if [[ ! -x "$haxe" ]]; then
	echo "missing Haxe executable: $haxe" >&2
	exit 1
fi

mkdir -p "$workspace_dir/suite/src"
printf '%s\n' '{"version":1,"package":{"name":"suite"},"entry":"Main","sourceRoots":["src"]}' > "$workspace_dir/suite/haxeon.json"
cat > "$workspace_dir/suite/src/Main.hx" <<'HX'
import haxeon.test.Shards;
import haxeon.test.Shards.TestGroup;

function main():Int {
	var groups:Array<TestGroup> = [
		{name: "alpha", run: () -> Sys.println("ran alpha"), weight: 5.0},
		{name: "beta", run: () -> Sys.println("ran beta"), weight: 1.0},
		{name: "gamma", run: () -> Sys.println("ran gamma"), weight: 3.0},
		{name: "delta", run: () -> Sys.println("ran delta"), weight: 1.0},
		{name: "epsilon", run: () -> Sys.println("ran epsilon"), weight: 2.0},
		{name: "zeta", run: () -> Sys.println("ran zeta"), weight: 1.0}
	];
	Shards.run(groups);
	return 0;
}
HX

write_workspace() {
	printf '%s\n' "{\"version\":1,\"buildDir\":\"build/workspace\",\"projects\":[{\"path\":\"suite/haxeon.json\",\"name\":\"suite\",\"shards\":$1}]}" > "$workspace_dir/workspace.json"
}

run_cli() {
	HAXEON_HOME="$home" HAXEON_SOURCE_CACHE="$source_cache" HAXEON_COMPILER_SOURCE="$repo_dir/src" "$haxe" --cwd "$repo_dir" -cp "$repo_dir/src" --run tools.HaxeonCli "$@"
}

# A shard count that is not a whole number of at least 1 is rejected before anything runs.
for bad in 0 -2 1.5; do
	write_workspace "$bad"
	if output=$(run_cli workspace plan --workspace "$workspace_dir/workspace.json" 2>&1); then
		echo "shards $bad was accepted" >&2
		exit 1
	fi
	[[ "$output" == *'"shards" must be a whole number of at least 1'* ]]
done

# Three shards run as three actions sharing one compile, and every group runs in exactly one of them.
write_workspace 3
output=$(run_cli workspace test --workspace "$workspace_dir/workspace.json" --jobs 4 2>&1)
[[ "$output" == *"pass  suite#1of3"* && "$output" == *"pass  suite#2of3"* && "$output" == *"pass  suite#3of3"* ]]
[[ "$(grep -c 'compile-project' <<<"$output")" -le 2 ]]
logs="$workspace_dir/build/workspace/tests"
for group in alpha beta gamma delta epsilon zeta; do
	count=$(cat "$logs"/suite#*of3.log | grep -c "^ran $group$" || true)
	[[ "$count" == "1" ]] || { echo "group $group ran $count times" >&2; exit 1; }
done

# A rerun with nothing changed is served from the cache, shard by shard.
output=$(run_cli workspace test --workspace "$workspace_dir/workspace.json" --jobs 4 2>&1)
[[ "$output" == *"pass (cached)  suite#1of3"* && "$output" == *"pass (cached)  suite#3of3"* ]]

echo "PASS: workspace test shards run every group once, in parallel actions"
