#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cmake -P "$root_dir/cmake/Bootstrap.cmake"
