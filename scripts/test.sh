#!/usr/bin/env bash
# The suites CI runs: the `ci` mode of tests/suites.txt, which lists them in order with how they are scheduled.
#
#   scripts/test.sh [--only NAME,...] [--list]
#
# TEST_JOBS sets the job count (default 16); SKIP_FORMAT_CHECK=1 skips the format check. Every suite runs even when an earlier one
# fails; the exit code is 0 only if every suite that ran passed. Logs and summary.txt go to out/test/<time>-ci/.
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/.." && pwd)
# scripts/haxeon runs on the checkout-built HashLink, so it is built first (a no-op when it is up to date).
"$root_dir/scripts/build-native.sh" >/dev/null
exec "$root_dir/scripts/haxeon" dev test ci "$@"
