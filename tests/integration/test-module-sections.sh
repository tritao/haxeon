#!/usr/bin/env bash
# Module sections (docs/design/MODULE_SECTIONS.md): a plain build with --module-sections writes HLB 9, which the VM links when it
# loads it. For a development build of a program (opcode source spans and source snapshots in its sections) and for the compiler's
# own release build, the VM's link holds exactly the tables, functions and names of the HLB 8 module the compiler's static link
# makes of the file (`haxeon dev hl-stat --link`, `code_link --compare`), and the sectioned build runs as the dense one does: the
# program prints the same, the sectioned compiler writes the same module.
set -euo pipefail
source "$(dirname "$0")/../../scripts/lib/env.sh"
haxeon_require_hashlink
haxeon_export_library_path

work="$haxeon_suite_out/module-sections"
mkdir -p "$work"
hl="$("$haxeon_root/scripts/hashlink-path.sh")/hl"
compiler=${HAXEON_COMPILER_HL:-$("$haxeon_root/scripts/haxeon" dev tool-path compiler.tools.HaxeonCompiler)}
code_link=$(haxeon_native_test code_link)
mode=$("$haxeon_root/scripts/haxeon" dev tool-build-mode)

# The static link of `$1` equals the VM's.
same_link() {
	"$haxeon_root/scripts/haxeon" dev hl-stat "$1" --link "$1.linked"
	if ! "$code_link" --compare "$1" "$1.linked" > "$1.compare.log" 2>&1; then
		tail -n 20 "$1.compare.log" >&2
		echo "FAIL: the VM's link of $1 differs from the static link" >&2
		exit 1
	fi
}

# Two modules, the standard library's and the shared section, with what crosses between them: calls, interfaces, statics,
# enums, closures, exceptions and anonymous structures.
fixture=tests/fixtures/module-sections
program=(--entry=app.Main "--root=$fixture" --root=stdlib "$fixture/app/Main.hx" "$fixture/lib/Shapes.hx")
for format in dense sections; do
	flags=()
	[[ $format == sections ]] && flags=(--module-sections --check-reuse)
	(cd "$haxeon_root" && "$hl" "$compiler" "${flags[@]}" "${program[@]}" "--output=$work/program-$format.hl") \
		> "$work/program-$format.log" 2>&1 || { cat "$work/program-$format.log" >&2; exit 1; }
	"$hl" "$work/program-$format.hl" > "$work/program-$format.out" 2>&1
done
[[ $(head -c 4 "$work/program-sections.hl" | od -An -tu1 | awk '{print $4}') == 9 ]] || { echo "FAIL: not HLB 9" >&2; exit 1; }
cmp "$work/program-dense.out" "$work/program-sections.out" || { echo "FAIL: the sectioned program prints otherwise" >&2; exit 1; }
same_link "$work/program-sections.hl"
"$haxeon_root/scripts/haxeon" dev hl-stat "$work/program-sections.hl" --sections | grep -q "opcode source spans" \
	|| { echo "FAIL: the development build's sections carry no opcode source spans" >&2; exit 1; }
echo "PASS: a development build's sections link as the static link does, and run"

roots=(src lib/haxeon-io stdlib)
(cd "$haxeon_root" && find "${roots[@]}" -name '*.hx' | LC_ALL=C sort) > "$work/sources.txt"
(cd "$haxeon_root" && "$hl" "$compiler" "--build-mode=$mode" --module-sections --entry=compiler.tools.HaxeonCompiler \
	"${roots[@]/#/--root=}" "--sources-file=$work/sources.txt" "--output=$work/compiler.hl") > "$work/compiler.log" 2>&1 \
	|| { tail -n 40 "$work/compiler.log" >&2; exit 1; }
same_link "$work/compiler.hl"
for build in dense sections; do
	with=$compiler
	[[ $build == sections ]] && with=$work/compiler.hl
	(cd "$haxeon_root" && "$hl" "$with" "${program[@]}" "--output=$work/by-$build.hl") > "$work/by-$build.log" 2>&1 \
		|| { cat "$work/by-$build.log" >&2; exit 1; }
done
cmp "$work/by-dense.hl" "$work/by-sections.hl" || { echo "FAIL: the sectioned compiler writes another module" >&2; exit 1; }
echo "PASS: the compiler's own sections link as the static link does, and it compiles as the dense build does"
