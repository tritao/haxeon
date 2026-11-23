#!/usr/bin/env bash
# Every module of the compiler and the build tool type-checks with stock Haxe, not only the ones the entry point reaches, and so
# does every test main of tests/compiler, with the class paths the test driver builds them with (tests/driver/TestRunner.hx,
# testClassPath). A switch over an IR enum in a module only tests compile (IrInterpreter) once broke the wave, and a main that
# imports a type a change deleted or renamed fails here in seconds rather than in the test driver. The pre-push hook runs it when a
# push deletes or renames a file under src/ (scripts/hooks/pre-push).
#
# The includes name their class path: under -cp tests, tests/compiler is the package `compiler` too.
set -euo pipefail
source "$(dirname "$0")/../../scripts/lib/env.sh"
haxeon_require_haxe

"$haxeon_haxe" --cwd "$haxeon_root" common.hxml -cp tests -cp tests/compiler -cp tests/runtime -cp tests/tooling \
	--macro "include('compiler', true, null, ['src'])" --macro "include('build', true, null, ['src'])" \
	--macro "include('', false, null, ['tests/compiler'])" -hl "$haxeon_suite_out/type-check-all.hl" --no-output -main Main
echo "PASS: the compiler, the build tool and the tests/compiler mains type-check with stock Haxe"
