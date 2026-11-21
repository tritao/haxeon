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
			case "hlc": HashLinkC;
			case "wasm32": Wasm32;
			case "wasm64": Wasm64;
			case "wasmgc" | "wasm-gc": WasmGc;
			default: null;
		};

	/** The names a compile can be asked for, for a message that lists them (`wasm64` parses but is not implemented). */
	public static function names():Array<String>
		return ["hl", "wasm32", "wasm-gc"];

	public static function isWasm(target:BackendTarget):Bool
		return switch target {
			case HashLink | HashLinkC: false;
			case Wasm32 | Wasm64 | WasmGc: true;
		};

	/** Whether the target runs on the HashLink runtime, with its types, layouts and natives: the JIT's or C's. */
	public static function isHashLink(target:BackendTarget):Bool
		return switch target {
			case HashLink | HashLinkC: true;
			case Wasm32 | Wasm64 | WasmGc: false;
		};
}
