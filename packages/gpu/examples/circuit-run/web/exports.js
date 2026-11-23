"use strict";

const fs = require("node:fs");
const [guestPath, outputPath] = process.argv.slice(2);
const guest = new WebAssembly.Module(fs.readFileSync(guestPath));
const libraries = new Set(["nativekit", "nativekit_gpu", "nativekit_ui"]);
const symbols = new Set(["_main", "_malloc", "_free"]);
for (const entry of WebAssembly.Module.imports(guest)) {
  if (entry.kind === "function" && libraries.has(entry.module))
    symbols.add("_" + entry.name);
}
fs.writeFileSync(outputPath, JSON.stringify([...symbols].sort()) + "\n");
