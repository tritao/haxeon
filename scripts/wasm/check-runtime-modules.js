// Checks the wasm32 runtime modules scripts/build_wasm_runtime.hx builds: `node check-runtime-modules.js MODULE...`.
//
// A runtime imports only linear memory and haxeon_guest functions, exports only functions, and has no table, global,
// start, data-count or element section (the compiler links functions only). A runtime-neutral variant ("-neutral.wasm")
// imports haxeon_guest.fuel_charge and at most haxeon_guest.collect besides, and may carry wasm-ld's private C stack
// global and empty table: the compiler links the global and rejects every call_indirect or element use of that table.
const fs = require("fs");

for (const runtimePath of process.argv.slice(2)) {
	const bytes = fs.readFileSync(runtimePath);
	const module = new WebAssembly.Module(bytes);
	const neutral = runtimePath.includes("-neutral.wasm");
	for (const entry of WebAssembly.Module.imports(module)) {
		const allowed = (entry.module === "env" && entry.name === "memory" && entry.kind === "memory")
			|| (entry.module === "haxeon_guest" && entry.kind === "function");
		if (!allowed)
			throw new Error(`the wasm32 runtime imports ${entry.module}.${entry.name} (${entry.kind})`);
	}
	if (neutral) {
		const fuelImports = WebAssembly.Module.imports(module).filter(entry => entry.module === "haxeon_guest");
		if (!fuelImports.some(entry => entry.name === "fuel_charge" && entry.kind === "function")
			|| fuelImports.some(entry => !["collect", "fuel_charge"].includes(entry.name) || entry.kind !== "function"))
			throw new Error(`the runtime-neutral module ${runtimePath} has an unexpected guest import surface`);
	}
	for (const entry of WebAssembly.Module.exports(module))
		if (entry.kind !== "function")
			throw new Error(`the wasm32 runtime exports ${entry.kind} ${entry.name}`);
	for (let offset = 8; offset < bytes.length;) {
		const id = bytes[offset++];
		let size = 0, shift = 0, byte;
		do {
			byte = bytes[offset++];
			size |= (byte & 0x7f) << shift;
			shift += 7;
		} while (byte & 0x80);
		if ([9, 11, 12].includes(id) || (!neutral && [4, 6].includes(id)))
			throw new Error(`the wasm32 runtime ${runtimePath} has unsupported section ${id}`);
		offset += size;
	}
}
