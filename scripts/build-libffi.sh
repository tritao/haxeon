#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
submodule_dir="$root_dir/vendor/libffi"
install_root="$root_dir/.tools/libffi-static"
mode=${1:-native}
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
case "$mode" in
	native)
		build_dir="$root_dir/out/libffi/native-static"
		install_dir="$install_root"
		stamp_value="$revision native-static $(uname -s)-$(uname -m)"
		;;
	--msvc)
		build_dir="$root_dir/out/libffi/msvc-x64-static-release"
		install_dir="$install_root/msvc-release"
		stamp_value="$revision msvc-x64-static-release"
		;;
	--msvc-debug)
		build_dir="$root_dir/out/libffi/msvc-x64-static-debug"
		install_dir="$install_root/msvc-debug"
		stamp_value="$revision msvc-x64-static-debug"
		;;
	*)
		echo "usage: $0 [--msvc|--msvc-debug]" >&2
		exit 2
		;;
esac

stamp_file="$install_dir/.haxeon-build"
static_library_installed=false
for candidate in \
	"$install_dir/lib/libffi.a" \
	"$install_dir/lib/libffi.lib" \
	"$install_dir/lib/libffi-8.lib" \
	"$install_dir/lib/ffi.lib" \
	"$install_dir/lib/ffi-8.lib"; do
	if [[ -f "$candidate" ]]; then
		static_library_installed=true
		break
	fi
done
if [[ -f "$stamp_file" && -f "$install_dir/include/ffi.h" ]] \
	&& [[ "$static_library_installed" == true ]] \
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

if [[ "$mode" == --msvc || "$mode" == --msvc-debug ]]; then
	# Match the upstream libffi MSVC build: use its GCC-to-MSVC wrapper while
	# running configure/make in Cygwin, and link with the runner's MSVC tools.
	msvc_cppflags=-DFFI_STATIC_BUILD
	if [[ "$mode" == --msvc-debug ]]; then msvc_cppflags+=" -DUSE_DEBUG_RTL"; fi
	host=x86_64-w64-mingw32
	CC="$source_dir/msvcc.sh -m64" \
	CXX="$source_dir/msvcc.sh -m64" \
	LD=link \
	LDFLAGS=-no-undefined \
	CPP='cl -nologo -EP' \
	CXXCPP='cl -nologo -EP' \
	CPPFLAGS="$msvc_cppflags" \
	CFLAGS="$msvc_cppflags" \
	AR="$source_dir/.ci/ar-lib lib" \
	RANLIB=: \
	NM='dumpbin -symbols' \
	STRIP=: \
		"$source_dir/configure" \
			--prefix="$install_dir" \
			--build="$host" --host="$host" \
			--enable-static --disable-shared --with-pic --disable-docs
else
	"$source_dir/configure" \
		--prefix="$install_dir" \
		--enable-static --disable-shared --with-pic --disable-docs
fi

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
