package compiler.backend.wasm.gc;

import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmTypes.WasmInstruction;

/** Remove local round trips and unused local slots after GC function lowering. */
class WasmGcLocalCompaction {
	public static function run(body:Array<WasmInstruction>, locals:Array<WasmLocal>, parameters:Int):{body:Array<WasmInstruction>, locals:Array<WasmLocal>} {
		var current = body, previousLength:Int;
		do {
			previousLength = current.length;
			current = forward(current);
		} while (current.length < previousLength);
		var used:Map<Int, Bool> = [],
			indices:Map<Int, Int> = [],
			retained:Array<WasmLocal> = [];
		for (instruction in current)
			switch instruction {
				case LocalGet(index), LocalSet(index), LocalTee(index):
					used.set(index, true);
				default:
			}
		for (index in 0...locals.length)
			if (used.exists(parameters + index)) {
				indices.set(parameters + index, parameters + retained.length);
				retained.push(locals[index]);
			}
		function translated(index:Int):Int {
			if (index < parameters)
				return index;
			var result = indices.get(index);
			if (result == null)
				throw 'Missing Wasm local $index during compaction';
			return result;
		}
		return {
			body: [
				for (instruction in current)
					switch instruction {
						case LocalGet(index):
							LocalGet(translated(index));
						case LocalSet(index):
							LocalSet(translated(index));
						case LocalTee(index):
							LocalTee(translated(index));
						default:
							instruction;
					}
			],
			locals: retained
		};
	}

	static function forward(body:Array<WasmInstruction>):Array<WasmInstruction> {
		var reads:Map<Int, Int> = [];
		for (instruction in body)
			switch instruction {
				case LocalGet(index):
					reads.set(index, (reads.exists(index) ? reads.get(index) : 0) + 1);
				default:
			}
		var result:Array<WasmInstruction> = [], index = 0;
		while (index < body.length) {
			if (index + 1 < body.length)
				switch [body[index], body[index + 1]] {
					case [LocalSet(left), LocalGet(right)] if (left == right):
						if (reads.get(left) != 1)
							result.push(LocalTee(left));
						index += 2;
						continue;
					case [I32Const(_), LocalSet(local)] | [I64Const(_), LocalSet(local)] | [F64Const(_), LocalSet(local)] | [RefNull(_), LocalSet(local)] |
						[LocalGet(_), LocalSet(local)] if (!reads.exists(local)):
						index += 2;
						continue;
					default:
				}
			result.push(body[index++]);
		}
		return result;
	}
}
