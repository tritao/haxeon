#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
"$repo_dir/.tools/haxe/haxe" --cwd "$repo_dir" -cp src -cp tests --run DebugMetadataMain
