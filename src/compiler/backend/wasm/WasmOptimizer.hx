package compiler.backend.wasm;

import compiler.backend.wasm.WasmTypes.WasmInstruction;

/** Small target-level cleanup pass that is safe before an external Wasm optimizer. */
class WasmOptimizer {
	public static function optimize(input:Array<WasmInstruction>):Array<WasmInstruction> {
		var current = input.copy(), changed = true;
		while (changed) {
			changed = false;
			var next:Array<WasmInstruction> = [];
			var index = 0;
			while (index < current.length) {
				if (index + 1 < current.length)
					switch [current[index], current[index + 1]] {
						case [Nop, instruction]:
							next.push(instruction);
							index += 2;
							changed = true;
							continue;
						case [LocalGet(left), LocalSet(right)] if (left == right):
							index += 2;
							changed = true;
							continue;
						default:
					}
				if (index + 2 < current.length) {
					var folded:Null<WasmInstruction> = fold(current[index], current[index + 1], current[index + 2]);
					if (folded != null) {
						next.push(folded);
						index += 3;
						changed = true;
						continue;
					}
				}
				next.push(current[index++]);
			}
			current = next;
		}
		return current;
	}

	static function fold(left:WasmInstruction, right:WasmInstruction, operation:WasmInstruction):Null<WasmInstruction> {
		return switch [left, right, operation] {
			case [I32Const(a), I32Const(b), I32Add]: I32Const(a + b);
			case [I32Const(a), I32Const(b), I32Sub]: I32Const(a - b);
			case [I32Const(a), I32Const(b), I32Mul]: I32Const(a * b);
			case [I32Const(a), I32Const(b), I32And]: I32Const(a & b);
			case [I32Const(a), I32Const(b), I32Xor]: I32Const(a ^ b);
			case [I32Const(a), I32Const(b), I32Or]: I32Const(a | b);
			case [I32Const(a), I32Const(b), I32Shl]: I32Const(a << (b & 31));
			case [I32Const(a), I32Const(b), I32ShrS]: I32Const(a >> (b & 31));
			case [I32Const(a), I32Const(b), I32ShrU]: I32Const(a >>> (b & 31));
			case [I32Const(a), I32Const(b), I32Eq]: I32Const(a == b ? 1 : 0);
			case [I32Const(a), I32Const(b), I32LtS]: I32Const(a < b ? 1 : 0);
			case [I32Const(a), I32Const(b), I32LeS]: I32Const(a <= b ? 1 : 0);
			case [F64Const(a), F64Const(b), F64Add]: F64Const(a + b);
			case [F64Const(a), F64Const(b), F64Sub]: F64Const(a - b);
			case [F64Const(a), F64Const(b), F64Mul]: F64Const(a * b);
			case [F64Const(a), F64Const(b), F64Div] if (b != 0): F64Const(a / b);
			case [F64Const(a), F64Const(b), F64Eq]: I32Const(a == b ? 1 : 0);
			case [F64Const(a), F64Const(b), F64Lt]: I32Const(a < b ? 1 : 0);
			case [F64Const(a), F64Const(b), F64Le]: I32Const(a <= b ? 1 : 0);
			default: null;
		};
	}
}
