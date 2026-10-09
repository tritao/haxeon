#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-sha256.XXXXXX")
trap 'rm -rf -- "${temporary_dir:?}"' EXIT
export LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
.tools/haxe/haxe -cp src -main compiler.tools.HaxeonCompiler -hl "$temporary_dir/compiler.hl"
for target in hl wasm32 wasm-gc; do
  .tools/hashlink/hl "$temporary_dir/compiler.hl" --target="$target" --output="$temporary_dir/sha256.$target" --entry=sha256 --root=tests/programs tests/programs/sha256.hx > "$temporary_dir/$target.log" 2>&1 || { cat "$temporary_dir/$target.log"; exit 1; }
done
set +e
.tools/hashlink/hl "$temporary_dir/sha256.hl"
result=$?
set -e
[[ "$result" == 42 ]] || { echo "native SHA-256 failed: $result"; exit 1; }
node - "$temporary_dir" <<'JS'
const fs = require('fs');
(async () => {
  for (const target of ['wasm32', 'wasm-gc']) {
    const {instance} = await WebAssembly.instantiate(fs.readFileSync(`${process.argv[2]}/sha256.${target}`), {});
    const result = instance.exports.main();
    if (result !== 42) throw Error(`${target} SHA-256 failed: ${result}`);
    console.log(`${target}: SHA-256 vectors and portable parity passed`);
  }
})().catch(error => { console.error(error); process.exit(1); });
JS
echo "native: SHA-256 vectors and portable parity passed"
