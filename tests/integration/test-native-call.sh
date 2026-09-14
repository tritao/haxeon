#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$repo_dir/out"

"$repo_dir/scripts/build-native.sh"
fixture_path=$(bash "$repo_dir/tests/integration/build-native-call-fixture.sh")
"$repo_dir/.tools/haxe/haxe" "$repo_dir/tests/hxml/native-call-test.hxml"
(
	cd "$repo_dir/out"
	"$repo_dir/.tools/hashlink/hl" native-call-test.hl "$fixture_path"
)
