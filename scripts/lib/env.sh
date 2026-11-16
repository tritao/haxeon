# Shared setup for scripts that run this checkout's tools. Source it; it defines functions and three variables and runs nothing:
#
#   source "$root_dir/scripts/lib/env.sh"
#   haxeon_require_haxe                 # exit 1, saying how to fix it, unless the pinned Haxe is installed
#   haxeon_require_hashlink             # exit 1 unless the checkout-built HashLink is
#   haxeon_export_library_path [DIR...] # put out/, the HashLink directory and DIRs on the library path
#   haxeon_timeout SECONDS COMMAND...   # run COMMAND, stopped after SECONDS, like GNU timeout (macOS has none)
#   haxeon_shared_library NAME          # the file a CMake shared library NAME builds to here: libNAME.so, libNAME.dylib, NAME.dll
#   haxeon_cc_libhl [--hdll] OUT SRC... # build a test program (or HashLink library) against libhl: cc, or cl on Windows
#
# haxeon_root is the repository root and haxeon_haxe the pinned Haxe, wherever the sourcing script lives. haxeon_suite_out is where a
# test writes the files it reads back: HAXEON_SUITE_OUT, the directory of its own the suite runner gives each suite, else out/ (a run by
# hand). Tests that may run beside another suite write there, never to fixed paths under out/; tests/SuiteOutput.hx is the Haxe side.

haxeon_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
haxeon_haxe="$haxeon_root/.tools/haxe/haxe"
haxeon_suite_out=${HAXEON_SUITE_OUT:-$haxeon_root/out}

haxeon_require_haxe() {
	if [[ ! -x $haxeon_haxe ]]; then
		echo "missing pinned Haxe: $haxeon_haxe; run scripts/bootstrap-tools.sh first" >&2
		exit 1
	fi
}

haxeon_require_hashlink() {
	local directory
	directory=$("$haxeon_root/scripts/hashlink-path.sh") || exit 1
	if [[ ! -x $directory/hl ]]; then
		echo "missing checkout-built HashLink: $directory/hl; run scripts/build-native.sh first" >&2
		exit 1
	fi
}

# Prepends to every variable a platform reads, so a script works unchanged on Linux (LD_LIBRARY_PATH), macOS
# (DYLD_LIBRARY_PATH) and Windows shells (PATH).
haxeon_export_library_path() {
	local directories directory
	directories="$haxeon_root/out:$("$haxeon_root/scripts/hashlink-path.sh")" || exit 1
	for directory in "$@"; do
		directories+=":$directory"
	done
	export LD_LIBRARY_PATH="$directories${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	export DYLD_LIBRARY_PATH="$directories${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
	case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*) export PATH="$directories:$PATH" ;;
	esac
}

# Runs COMMAND, stopped after SECONDS (a trailing s is allowed), with GNU timeout's statuses: COMMAND's own, 124 when the limit
# stopped it, 128+N when signal N ended it. macOS has no timeout(1), and Perl is on every host the tests run on. COMMAND runs in
# a process group of its own and the whole group is stopped, so a launcher's children (scripts/haxeon run starts hl) stop with
# it. COMMAND must be a program, not a shell function.
haxeon_timeout() {
	local limit=${1%s}
	shift
	perl -e '
		my $limit = shift;
		my $pid = fork() // die "haxeon_timeout: fork: $!\n";
		if ($pid == 0) {
			setpgrp(0, 0);
			exec { $ARGV[0] } @ARGV;
			print STDERR "haxeon_timeout: $ARGV[0]: $!\n";
			exit 127;
		}
		for my $signal (qw(HUP INT TERM)) {
			$SIG{$signal} = sub { kill $signal, -$pid; };
		}
		$SIG{ALRM} = sub {
			print STDERR "haxeon_timeout: $ARGV[0] still running after ${limit}s; stopping it\n";
			kill "TERM", -$pid;
			sleep 2;
			kill "KILL", -$pid;
			waitpid($pid, 0);
			exit 124;
		};
		alarm $limit;
		while (waitpid($pid, 0) != $pid) {}
		exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
	' "$limit" "$@"
}

# The file name a CMake shared library target builds to on this platform.
haxeon_shared_library() {
	case "$(uname -s)" in
	Darwin) printf 'lib%s.dylib' "$1" ;;
	MINGW* | MSYS* | CYGWIN*) printf '%s.dll' "$1" ;;
	*) printf 'lib%s.so' "$1" ;;
	esac
}

# Builds C sources against this checkout's VM into OUTPUT: a program that hosts the VM itself, linked with the static VM core
# (libhl.a, libhl.lib with MSVC: everything in hl but main.c), or with --hdll a HashLink library for hl to load, which takes
# the VM's API from the executable that loads it. cc on Linux and macOS; on Windows MSVC's cl, which the VM is built with (the
# shell's MinGW cannot link it; the Windows job sets up MSVC's environment). CFLAGS adds compiler flags for cc; the library
# directory is HL_GC_TEST_LIBRARY_DIR or the checkout's HashLink directory.
haxeon_cc_libhl() {
	local hdll= output library source sources=()
	if [[ $1 == --hdll ]]; then
		hdll=1
		shift
	fi
	output=$1
	shift
	library=${HL_GC_TEST_LIBRARY_DIR:-$("$haxeon_root/scripts/hashlink-path.sh")}
	case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*)
		for source in "$@"; do
			sources+=("$(cygpath -w "$source")")
		done
		# A library links hl.lib, the executable's import library; a program links the static core and what it needs.
		local libraries flags
		if [[ -n $hdll ]]; then
			flags=(-LD)
			libraries=(hl.lib)
		else
			# LIBHL_STATIC: the program defines the VM's functions itself rather than importing them from a DLL. It links the static
			# core's objects, so it takes their C runtime: the DLL one (-MD), or its debug variant in a Debug build (-MDd).
			flags=(-DLIBHL_STATIC -MD)
			if grep -qs '^CMAKE_BUILD_TYPE:STRING=Debug$' "$library/../CMakeCache.txt"; then
				flags=(-DLIBHL_STATIC -MDd)
			fi
			libraries=(libhl.lib ws2_32.lib user32.lib winmm.lib dbghelp.lib advapi32.lib bcrypt.lib)
		fi
		# cl writes its diagnostics to standard output, with a line per file: show them only when the build fails.
		local log status=0
		log=$(MSYS2_ARG_CONV_EXCL='*' cl -nologo -O2 "${flags[@]}" -I"$(cygpath -w "$haxeon_root/vendor/hashlink/src")" \
			"${sources[@]}" -Fo"$(cygpath -w "$(dirname "$output")")\\" -Fe"$(cygpath -w "$output")" -link \
			-LIBPATH:"$(cygpath -w "$library")" "${libraries[@]}") || status=$?
		if [[ $status != 0 ]]; then
			printf '%s\n' "$log" >&2
			return "$status"
		fi
		;;
	Darwin)
		if [[ -n $hdll ]]; then
			# shellcheck disable=SC2086 # CFLAGS holds several flags
			"${CC:-cc}" ${CFLAGS:-} -shared -fPIC -Wl,-undefined,dynamic_lookup -I"$haxeon_root/vendor/hashlink/src" "$@" -o "$output"
		else
			# shellcheck disable=SC2086
			"${CC:-cc}" ${CFLAGS:-} -I"$haxeon_root/vendor/hashlink/src" "$@" -L"$library" -lhl -lm -ldl -lpthread -o "$output"
		fi
		;;
	*)
		if [[ -n $hdll ]]; then
			# shellcheck disable=SC2086 # CFLAGS holds several flags
			"${CC:-cc}" ${CFLAGS:-} -shared -fPIC -I"$haxeon_root/vendor/hashlink/src" "$@" -o "$output"
		else
			# The program exports the VM's API, as hl does, to the libraries it loads.
			# shellcheck disable=SC2086
			"${CC:-cc}" ${CFLAGS:-} -rdynamic -I"$haxeon_root/vendor/hashlink/src" "$@" -L"$library" -lhl -lm -ldl -lpthread -o "$output"
		fi
		;;
	esac
}
