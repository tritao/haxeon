#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
chrome_bin=${CHROME_BIN:-google-chrome}
wasm_path="$root_dir/out/wasm-gc-chrome-smoke.wasm"
page_path="$root_dir/out/wasm-gc-chrome-smoke.html"
dom_path="$root_dir/out/wasm-gc-chrome-smoke.dom"

if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi
if ! command -v "$chrome_bin" >/dev/null 2>&1; then
	echo "missing Chrome; set CHROME_BIN or install Google Chrome" >&2
	exit 1
fi

mkdir -p "$root_dir/out"
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm-gc --output="$wasm_path" --entry=wasm-gc-objects \
	--root=tests/programs tests/programs/wasm-gc-objects.hx

node - "$wasm_path" "$page_path" <<'JS'
const fs = require("fs");
const wasm = fs.readFileSync(process.argv[2]).toString("base64");
const html = `<!doctype html>
<meta charset="utf-8">
<title>Wasm GC smoke test</title>
<pre id="result">RUNNING</pre>
<script>
try {
  const bytes = Uint8Array.from(atob("${wasm}"), character => character.charCodeAt(0));
  const module = new WebAssembly.Module(bytes);
  const imports = WebAssembly.Module.imports(module);
  const exports = WebAssembly.Module.exports(module);
  if (imports.length !== 0) throw new Error("unexpected imports: " + imports.map(item => item.name).join(", "));
  if (exports.some(item => item.name === "memory")) throw new Error("GC module exported linear memory");
  const instance = new WebAssembly.Instance(module, {});
  const result = instance.exports.main();
  if (result !== 42) throw new Error("expected main() to return 42, got " + result);
  document.getElementById("result").textContent = "PASS: Wasm GC objects executed in Chrome";
} catch (error) {
  document.getElementById("result").textContent = "FAIL: " + error.message;
}
</script>`;
fs.writeFileSync(process.argv[3], html);
JS

page_url=$(node -e 'process.stdout.write(require("url").pathToFileURL(process.argv[1]).href)' "$page_path")
"$chrome_bin" --headless --no-sandbox --disable-gpu --disable-dev-shm-usage --dump-dom "$page_url" > "$dom_path"
if ! grep -Fq "PASS: Wasm GC objects executed in Chrome" "$dom_path"; then
	cat "$dom_path" >&2
	exit 1
fi

echo "PASS: Wasm GC module validated and executed in Chrome ($($chrome_bin --version))"
