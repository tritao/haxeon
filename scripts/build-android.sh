#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"

source "$root_dir/scripts/android-env.sh"
exec "$root_dir/android/gradlew" -p "$root_dir/android" "$@"
