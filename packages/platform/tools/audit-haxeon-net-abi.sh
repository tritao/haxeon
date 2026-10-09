#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
platform_dir="$haxeon_dir/packages/platform"

"$haxeon_dir/scripts/haxeon-ffi-audit" \
	--target=x86_64-linux-gnu \
	--target=x86_64-w64-windows-gnu \
	--target=x86_64-apple-darwin \
	--target=arm64-apple-darwin \
	--profile=portable-abi64 \
	--library=nativekit \
	--interface=NativeKitNet \
	--depends=NativeKit \
	--dependency-hxi="$platform_dir/bindings/nativekit.hxi" \
	--include="$nativekit_dir/include" \
	--exclude-header="$nativekit_dir/include/nativekit.h" \
	--source-label=bindings/haxe/nativekit_net_import.h \
	"$@" \
	"$platform_dir/bindings/nativekit_net_import.h"
