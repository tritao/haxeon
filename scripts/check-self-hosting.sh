#!/usr/bin/env bash
# The self-hosting check is a Haxe script now: scripts/check-self-hosting.hx, run by haxeon. This name keeps working for the
# gates and habits that use it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/haxeon" "$here/check-self-hosting.hx" "$@"
