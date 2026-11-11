# Sourced by the Wasm test scripts; expects `root_dir` and `haxe_bin`.
#
# `haxe --run compiler.tools.HaxeonCompiler` re-interprets the whole compiler for every
# fixture (about 2.5 s each). The compiler is built to HashLink bytecode once instead and
# each fixture compiles in a fraction of a second. Nested scripts inherit the build through
# HAXEON_COMPILER_HL; concurrent runs build into their own temporary directory.
#
# The current sources are built by the checked-in haxeon compiler (bootstrap/compiler.hl).
# HAXEON_STOCK_HAXE_TOOLS=1 builds them with the pinned Haxe (`$haxe_bin -hl`) instead.

haxeon_hl="$root_dir/.tools/hashlink/hl"
haxeon_jobs=0
haxeon_failed=0
haxeon_max_jobs=${TEST_JOBS:-$(nproc 2>/dev/null || echo 4)}

if [[ -z ${HAXEON_COMPILER_HL:-} || ! -f $HAXEON_COMPILER_HL ]]; then
	mkdir -p "$root_dir/out/test-tools"
	haxeon_compiler_dir=$(mktemp -d "$root_dir/out/test-tools/haxeon-compiler.XXXXXX")
	trap 'rm -rf -- "$haxeon_compiler_dir"' EXIT
	export HAXEON_COMPILER_HL="$haxeon_compiler_dir/haxeon-compiler.hl"
	if [[ ${HAXEON_STOCK_HAXE_TOOLS:-} == 1 ]]; then
		"$haxe_bin" --cwd "$root_dir" -cp src -hl "$HAXEON_COMPILER_HL" -main compiler.tools.HaxeonCompiler
	else
		(cd "$root_dir" && find src stdlib -name '*.hx' | LC_ALL=C sort) >"$haxeon_compiler_dir/sources.txt"
		(
			cd "$root_dir"
			LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
				DYLD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
				"$haxeon_hl" bootstrap/compiler.hl "--output=$HAXEON_COMPILER_HL" --entry=compiler.tools.HaxeonCompiler \
				--root=src --root=stdlib "--sources-file=$haxeon_compiler_dir/sources.txt"
		) >"$haxeon_compiler_dir/build.log" 2>&1 || {
			tail -n 20 "$haxeon_compiler_dir/build.log" >&2
			echo "could not build the compiler with bootstrap/compiler.hl (HAXEON_STOCK_HAXE_TOOLS=1 uses the pinned Haxe)" >&2
			exit 1
		}
	fi
fi

# Compile with the prebuilt compiler; paths are relative to the repository root.
haxeon_compile() {
	(
		cd "$root_dir"
		LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			DYLD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
			"$haxeon_hl" "$HAXEON_COMPILER_HL" "$@"
	)
}

# Start a compile in the background, keeping at most haxeon_max_jobs running.
haxeon_compile_async() {
	if ((haxeon_jobs >= haxeon_max_jobs)); then
		wait -n || haxeon_failed=1
		haxeon_jobs=$((haxeon_jobs - 1))
	fi
	haxeon_compile "$@" &
	haxeon_jobs=$((haxeon_jobs + 1))
}

# Start a compile whose failure the caller reports itself: haxeon_compile_logged_async LOG ARGS...
haxeon_compile_logged_async() {
	local log=$1
	shift
	if ((haxeon_jobs >= haxeon_max_jobs)); then
		wait -n || haxeon_failed=1
		haxeon_jobs=$((haxeon_jobs - 1))
	fi
	{ haxeon_compile "$@" > "$log" 2>&1 || true; } &
	haxeon_jobs=$((haxeon_jobs + 1))
}

# Wait for every background compile; fails when any of them failed.
haxeon_compile_wait() {
	while ((haxeon_jobs > 0)); do
		wait -n || haxeon_failed=1
		haxeon_jobs=$((haxeon_jobs - 1))
	done
	if ((haxeon_failed != 0)); then
		echo "one or more Wasm fixture compilations failed" >&2
		return 1
	fi
}
