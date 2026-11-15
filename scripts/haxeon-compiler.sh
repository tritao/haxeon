# Sourced by the Wasm test scripts; expects `root_dir` and `haxe_bin`.
#
# `haxe --run compiler.tools.HaxeonCompiler` re-interprets the whole compiler for every
# fixture (about 2.5 s each). The compiler is built to HashLink bytecode instead, once per
# content of its sources (`haxeon dev tool-path`), and each fixture compiles in a fraction of
# a second. HAXEON_COMPILER_HL, when set, pins a specific compiler build instead.

hashlink_dir=$("$root_dir/scripts/hashlink-path.sh")
haxeon_hl="$hashlink_dir/hl"
if [[ ! -x "$haxeon_hl" ]]; then
	echo "Missing checkout-built HashLink: $haxeon_hl; run scripts/build-native.sh first" >&2
	return 1
fi
# The running background compiles, oldest first. The pool waits for its oldest compile rather than for whichever ends
# first (`wait -n`), which macOS's bash 3.2 lacks.
haxeon_pids=()
haxeon_failed=0
haxeon_max_jobs=${TEST_JOBS:-$(nproc 2>/dev/null || echo 4)}

if [[ -z ${HAXEON_COMPILER_HL:-} || ! -f $HAXEON_COMPILER_HL ]]; then
	export HAXEON_COMPILER_HL
	HAXEON_COMPILER_HL=$("$root_dir/scripts/haxeon" dev tool-path compiler.tools.HaxeonCompiler) || return 1
fi

# Compile with the prebuilt compiler; paths are relative to the repository root.
haxeon_compile() {
	(
		cd "$root_dir"
		LD_LIBRARY_PATH="$root_dir/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			DYLD_LIBRARY_PATH="$root_dir/out:$hashlink_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
			"$haxeon_hl" "$HAXEON_COMPILER_HL" "$@"
	)
}

# Wait for the oldest running compile and drop it from the pool.
haxeon_wait_oldest() {
	wait "${haxeon_pids[0]}" || haxeon_failed=1
	haxeon_pids=(${haxeon_pids[@]+"${haxeon_pids[@]:1}"})
}

# Start a compile in the background, keeping at most haxeon_max_jobs running.
haxeon_compile_async() {
	if ((${#haxeon_pids[@]} >= haxeon_max_jobs)); then
		haxeon_wait_oldest
	fi
	haxeon_compile "$@" &
	haxeon_pids+=($!)
}

# Start a compile whose failure the caller reports itself: haxeon_compile_logged_async LOG ARGS...
haxeon_compile_logged_async() {
	local log=$1
	shift
	if ((${#haxeon_pids[@]} >= haxeon_max_jobs)); then
		haxeon_wait_oldest
	fi
	{ haxeon_compile "$@" > "$log" 2>&1 || true; } &
	haxeon_pids+=($!)
}

# Wait for every background compile; fails when any of them failed.
haxeon_compile_wait() {
	while ((${#haxeon_pids[@]} > 0)); do
		haxeon_wait_oldest
	done
	if ((haxeon_failed != 0)); then
		echo "one or more Wasm fixture compilations failed" >&2
		return 1
	fi
}
