#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
	echo "usage: $0" >&2
	exit 2
fi

root_dir=$(cd "$(dirname "$0")/.." && pwd)
submodule_dir="$root_dir/vendor/libffi"
install_root="$root_dir/.tools/libffi-static"
git_safe_directory_args=(
	-c "safe.directory=$root_dir"
	-c "safe.directory=$submodule_dir"
)

if [[ ! -f "$submodule_dir/configure.ac" ]]; then
	echo "pinned libffi submodule is missing; initialize vendor/libffi first" >&2
	exit 1
fi

revision=$(git "${git_safe_directory_args[@]}" -C "$submodule_dir" rev-parse HEAD)
source_dir="$root_dir/out/libffi/source-$revision"
build_dir="$root_dir/out/libffi/native-static"
install_dir="$install_root"
stamp_value="$revision native-static $(uname -s)-$(uname -m)"

stamp_file="$install_dir/.haxeon-build"
if [[ -f "$stamp_file" && -f "$install_dir/include/ffi.h" ]] \
	&& [[ -f "$install_dir/lib/libffi.a" ]] \
	&& [[ "$(<"$stamp_file")" == "$stamp_value" ]]; then
	printf 'Pinned libffi %s is already installed\n' "$revision"
	exit 0
fi

for tool in autoreconf make tar; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "missing required libffi build tool: $tool" >&2
		exit 1
	fi
done

if [[ ! -f "$source_dir/configure.ac" ]]; then
	mkdir -p "$source_dir"
	git "${git_safe_directory_args[@]}" -C "$submodule_dir" archive HEAD | tar -x -C "$source_dir"
fi
cp "$root_dir/scripts/libffi-libtool-compat.m4" "$source_dir/m4/haxeon-libtool-compat.m4"
if ! grep -Fq 'haxeon-libtool-compat.m4' "$source_dir/acinclude.m4"; then
	printf '\nm4_include([m4/haxeon-libtool-compat.m4])\n' >> "$source_dir/acinclude.m4"
fi
(
	cd "$source_dir"
	autoreconf -f -v -i
)

mkdir -p "$build_dir" "$install_dir"
cd "$build_dir"

"$source_dir/configure" \
	--prefix="$install_dir" \
	--enable-static --disable-shared --with-pic --disable-docs

if command -v getconf >/dev/null 2>&1; then
	jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')
else
	jobs=2
fi
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then jobs=2; fi
make -j"${BUILD_JOBS:-$jobs}"
make install

printf '%s\n' "$stamp_value" > "$stamp_file"
printf 'Built pinned libffi %s into %s\n' "$revision" "$install_dir"
