package compiler.backend.wasm;

import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir.IrType;

/** Representation selected below canonical Haxeon IR, never in the IR itself. */
enum WasmReferenceModel {
	Linear32;
	Linear64;
	Gc;
}

typedef WasmTargetConfig = {
	final target:BackendTarget;
	final referenceModel:WasmReferenceModel;
	final exceptions:Bool;
	final bulkMemory:Bool;
	final simd:Bool;
	final threads:Bool;
	final debugNames:Bool;
}

class WasmTarget {
	public static function forBackend(target:BackendTarget, ?debugNames:Bool = true):WasmTargetConfig {
		return switch target {
			case Wasm32: {
					target: target,
					referenceModel: Linear32,
					exceptions: true,
					bulkMemory: true,
					simd: false,
					threads: false,
					debugNames: debugNames
				};
			case Wasm64: {
					target: target,
					referenceModel: Linear64,
					exceptions: false,
					bulkMemory: true,
					simd: false,
					threads: false,
					debugNames: debugNames
				};
			case WasmGc: {
					target: target,
					referenceModel: Gc,
					exceptions: true,
					bulkMemory: true,
					simd: false,
					threads: false,
					debugNames: debugNames
				};
			case HashLink: throw "HashLink is not a Wasm target";
		};
	}

	public static function isReference(type:IrType):Bool
		return switch type {
			case Bytes, Dyn, Obj(_), Enum(_), Abstract(_), Virtual(_), Array(_), Function(_, _): true;
			default: false;
		};
}
