#!/usr/bin/env bash
# The compiler, as stock Haxe builds it (the tool compiler every other check uses), compiles the compiler's own sources: the entry
# point `tools.CompilerExecutable`, which reaches the CLI, the compile server, the language server and the compiler, to bytecode in
# the tool build mode. A change stock Haxe accepts but the compiler's own typer or checks reject (an error only Haxeon gives, a
# construct only `#if haxeon` declares) fails here, without the C build of `haxeon dev aot` or the stages of check-self-hosting.hx.
# The pre-push hook runs it too (scripts/hooks/pre-push).
set -euo pipefail
source "$(dirname "$0")/../../scripts/lib/env.sh"
haxeon_require_hashlink
haxeon_export_library_path

work="$haxeon_suite_out/self-build"
mkdir -p "$work"
compiler=${HAXEON_COMPILER_HL:-$("$haxeon_root/scripts/haxeon" dev tool-path compiler.tools.HaxeonCompiler)}
mode=$("$haxeon_root/scripts/haxeon" dev tool-build-mode)
roots=(src lib/haxeon-io stdlib)
(cd "$haxeon_root" && find "${roots[@]}" -name '*.hx' | LC_ALL=C sort) > "$work/sources.txt"

started=$SECONDS
if ! (cd "$haxeon_root" && "$("$haxeon_root/scripts/hashlink-path.sh")/hl" "$compiler" "--build-mode=$mode" \
	--entry=tools.CompilerExecutable "${roots[@]/#/--root=}" "--sources-file=$work/sources.txt" \
	"--output=$work/compiler-executable.hl") > "$work/compile.log" 2>&1; then
	tail -n 40 "$work/compile.log" >&2
	echo "FAIL: the compiler does not compile its own sources (tools.CompilerExecutable); log: $work/compile.log" >&2
	exit 1
fi
echo "PASS: the compiler compiles its own sources (tools.CompilerExecutable, $mode) in $((SECONDS - started)) s"
