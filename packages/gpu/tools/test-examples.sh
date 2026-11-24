#!/usr/bin/env bash
# Builds each GPU example and runs it under a virtual display. An example that fails to start exits early; one that is still
# drawing when the time runs out passes.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
seconds=${GPU_EXAMPLE_SECONDS:-10}

for example in triangle circuit-run; do
	project="$root/packages/gpu/examples/$example/haxeon.json"
	"$root/scripts/haxeon" build --project "$project"
	set +e
	xvfb-run -a timeout "$seconds" "$root/scripts/haxeon" run --project "$project"
	status=$?
	set -e
	if [[ $status -ne 124 ]]; then
		echo "test-examples: $example exited with $status before ${seconds}s" >&2
		exit 1
	fi
	echo "PASS: $example ran for ${seconds}s"
done
