#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
	echo "SKIP: VS Code DAP integration requires x64 Linux"
	exit 0
fi

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root/extensions/vscode"
npm ci
npm run build
cd "$root"
node tests/integration/test-vscode-debug.cjs
