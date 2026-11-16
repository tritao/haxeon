package compiler.backend;

import compiler.backend.Backend.BackendTarget;

/**
 * The one reading of a target name (`--target=`, the `target` define). Everything after the boundary that parses it holds the
 * `BackendTarget` and switches on it; nothing downstream compares target strings.
 */
class BackendTargets {
	/** The target a name selects, or null for a name that is not a backend target. */
	public static function parse(name:Null<String>):Null<BackendTarget>
		return switch name {
			case "hl": HashLink;
			case "wasm32": Wasm32;
			case "wasm64": Wasm64;
			case "wasmgc" | "wasm-gc": WasmGc;
			default: null;
		};

	public static function isWasm(target:BackendTarget):Bool
		return switch target {
			case HashLink: false;
			case Wasm32 | Wasm64 | WasmGc: true;
		};
}
