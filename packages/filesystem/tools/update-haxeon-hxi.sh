#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
platform_dir="$haxeon_dir/packages/platform"
output="$package_dir/bindings/nativekit-filesystem.hxi"
destination=$output

if [[ ${1:-} == "--check" ]]; then
	destination=$(mktemp)
	trap 'rm -f -- "$destination"' EXIT
elif [[ $# -ne 0 ]]; then
	echo "usage: tools/update-haxeon-hxi.sh [--check]" >&2
	exit 2
fi

"$haxeon_dir/scripts/haxeon" ffi audit \
	--target=x86_64-linux-gnu \
	--target=x86_64-w64-windows-gnu \
	--target=x86_64-apple-darwin \
	--target=arm64-apple-darwin \
	--profile=portable-abi64 \
	--library=nativekit_filesystem \
	--interface=NativeKitFilesystem \
	--depends=NativeKit \
	--dependency-hxi="$platform_dir/bindings/nativekit.hxi" \
	--include="$nativekit_dir/modules/filesystem/include" \
	--include="$package_dir/bindings" \
	--include="$nativekit_dir/include" \
	--exclude-header="$nativekit_dir/include/nativekit.h" \
	--source-label=modules/filesystem/bindings/nativekit_filesystem_import.h \
	--output="$destination" \
	"$package_dir/bindings/nativekit_filesystem_import.h"

if [[ ${1:-} == "--check" ]] && ! cmp -s "$output" "$destination"; then
	echo "Haxeon filesystem binding is stale; run tools/update-haxeon-hxi.sh" >&2
	diff -u "$output" "$destination" || true
	exit 1
fi
