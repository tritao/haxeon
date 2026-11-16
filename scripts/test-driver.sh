#!/usr/bin/env bash
# The test driver: `scripts/test-driver.sh [jobs] [--suite NAMES] [--test REGEX] [--list]`. The work is done by
# `haxeon dev test-driver` (src/tools/dev/TestDriverCommand.hx), which runs the driver on private copies of the VM and runtime.
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/.." && pwd)
# scripts/haxeon runs on the checkout-built HashLink, and the driver must not rebuild a library that process has loaded, so the
# native runtime is built first (a no-op when it is up to date, or when HAXEON_NATIVE_READY=1 says a caller did it).
"$root_dir/scripts/build-native.sh" >/dev/null
exec "$root_dir/scripts/haxeon" dev test-driver "$@"
