#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-json.XXXXXX")
trap 'rm -rf -- "${temporary_dir:?}"' EXIT
export LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
.tools/haxe/haxe -cp src -main compiler.tools.HaxeonCompiler -hl "$temporary_dir/compiler.hl"
for program in json-utf8-parser json-decoded-object-array json-typed-object-array; do
  for target in hl wasm32 wasm-gc; do
    .tools/hashlink/hl "$temporary_dir/compiler.hl" --target="$target" --output="$temporary_dir/$program.$target" --entry="$program" --root=tests/programs "tests/programs/$program.hx" > "$temporary_dir/build.log" 2>&1 || { cat "$temporary_dir/build.log"; exit 1; }
  done
  set +e
  .tools/hashlink/hl "$temporary_dir/$program.hl"
  result=$?
  set -e
  [[ "$result" == 42 ]] || { echo "native $program failed: $result"; exit 1; }
done
node - "$temporary_dir" <<'JS'
const fs = require('fs');
(async () => {
  for (const program of ['json-utf8-parser', 'json-decoded-object-array', 'json-typed-object-array']) {
    for (const target of ['wasm32', 'wasm-gc']) {
      const {instance} = await WebAssembly.instantiate(fs.readFileSync(`${process.argv[2]}/${program}.${target}`), {
        std: {sys_exit: code => {throw Error(`unexpected exit ${code}`);}},
        haxeon_runtime: {__math_abs: Math.abs}
      });
      const result = instance.exports.main();
      if (result !== 42) throw Error(`${target} ${program} failed: ${result}`);
    }
  }
})().catch(error => { console.error(error); process.exit(1); });
JS
echo "JSON parsing: native, wasm32 and wasm-gc passed Unicode, malformed input, large documents and typed arrays"
