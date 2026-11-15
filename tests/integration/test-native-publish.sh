#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-native-publish.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/from" "$fixture/to"

printf 'first\n' > "$fixture/from/libfirst.so"
ln -s libfirst.so "$fixture/from/libfirst.so.1"
printf 'unrelated\n' > "$fixture/to/foreign.hdll"
cmake -DFROM="$fixture/from" -DTO="$fixture/to" -P "$root_dir/cmake/haxeon-publish.cmake"
test "$(cat "$fixture/to/libfirst.so")" = first
test -L "$fixture/to/libfirst.so.1"
test "$(readlink "$fixture/to/libfirst.so.1")" = libfirst.so

rm "$fixture/from/libfirst.so"
rm "$fixture/from/libfirst.so.1"
printf 'second\n' > "$fixture/from/libsecond.so"
cmake -DFROM="$fixture/from" -DTO="$fixture/to" -P "$root_dir/cmake/haxeon-publish.cmake"
test ! -e "$fixture/to/libfirst.so"
test "$(cat "$fixture/to/libsecond.so")" = second
test "$(cat "$fixture/to/.haxeon-published")" = libsecond.so
test "$(cat "$fixture/to/foreign.hdll")" = unrelated
echo 'PASS: native publication replaces its own libraries and preserves other files'
