#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
platform_dir="$haxeon_dir/packages/platform"
output=${1:-"$package_dir/bindings/nativekit-credentials.hxi"}

"$haxeon_dir/scripts/haxeon-ffi-audit" \
	--target=x86_64-linux-gnu \
	--target=x86_64-w64-windows-gnu \
	--target=x86_64-apple-darwin \
	--target=arm64-apple-darwin \
	--profile=portable-abi64 \
	--library=nativekit_credentials \
	--interface=NativeKitCredentials \
	--depends=NativeKit \
	--dependency-hxi="$platform_dir/bindings/nativekit.hxi" \
	--include="$nativekit_dir/modules/credentials/include" \
	--include="$package_dir/bindings" \
	--include="$nativekit_dir/include" \
	--exclude-header="$nativekit_dir/include/nativekit.h" \
	--source-label=modules/credentials/bindings/nativekit_credentials_import.h \
	--output="$output" \
	"$package_dir/bindings/nativekit_credentials_import.h"

echo "check-hxi: wrote $output"
