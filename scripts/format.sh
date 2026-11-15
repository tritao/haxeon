#!/usr/bin/env bash
# Formats the Haxe sources of this checkout, or checks them: `scripts/format.sh [--check] [--changed]`. The work is done by
# `haxeon dev format` (src/tools/dev/FormatCommand.hx), so this wrapper stays within what macOS's bash 3.2 runs.
set -eu
exec "$(cd "$(dirname "$0")/.." && pwd)/scripts/haxeon" dev format "$@"
