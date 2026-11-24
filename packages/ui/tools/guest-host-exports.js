// Export the linked guest imports, plus the functions called directly by the browser shell.
const fs = require("fs");
const [guestPath, outputPath, ...interfaces] = process.argv.slice(2);
if (!guestPath || !outputPath) throw new Error("usage: guest-host-exports.js GUEST_WASM OUTPUT_JSON");
const linked = new Set(["nativekit", "nativekit_gpu", "nativekit_ui"]);
const names = new Set([
  "_main", "_malloc", "_free", "_nk_last_error", "_nkgpu_last_error",
  "_nkui_showcase_diagnostic_message", "_nkui_showcase_diagnostic_breadcrumbs", "_nkui_showcase_diagnostic_stack",
  "_nkui_haxeon_memory_contract_status", "_nkui_haxeon_memory_contract_version",
  "_nkui_haxeon_memory_contract_page_size", "_nkui_haxeon_memory_contract_host_base",
  "_nkui_haxeon_memory_contract_host_limit", "_nkui_haxeon_memory_contract_guest_base",
  "_nkui_haxeon_memory_contract_guest_limit", "_nkui_haxeon_memory_contract_memory_size"
]);
if (guestPath !== "-") {
  const guest = new WebAssembly.Module(fs.readFileSync(guestPath));
  for (const entry of WebAssembly.Module.imports(guest))
    if (entry.kind === "function" && linked.has(entry.module)) names.add("_" + entry.name);
}
for (const path of interfaces)
  for (const match of fs.readFileSync(path, "utf8").matchAll(/^\s*extern fn (\w+)\(/gm))
    names.add("_" + match[1]);
fs.writeFileSync(outputPath, JSON.stringify([...names].sort()) + "\n");
