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
				if (index + 1 < current.length) {
					var pair = rewritePair(current[index], current[index + 1]);
					if (pair != null)
						switch pair {
							case RemovePair:
								index += 2;
								changed = true;
								continue;
							case ReplacePair(instruction):
								next.push(instruction);
								index += 2;
								changed = true;
								continue;
						}
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

	static function rewritePair(left:WasmInstruction, right:WasmInstruction):Null<PairRewrite> {
		return switch left {
			case Nop: ReplacePair(right);
			case LocalGet(leftValue):
				switch right {
					case LocalSet(rightValue) if (leftValue == rightValue): RemovePair;
					default: null;
				}
			default: null;
		};
	}

	static function fold(left:WasmInstruction, right:WasmInstruction, operation:WasmInstruction):Null<WasmInstruction> {
		return switch operation {
			case I32Add: foldI32(left, right, I32Add);
			case I32Sub: foldI32(left, right, I32Sub);
			case I32Mul: foldI32(left, right, I32Mul);
			case I32And: foldI32(left, right, I32And);
			case I32Xor: foldI32(left, right, I32Xor);
			case I32Or: foldI32(left, right, I32Or);
			case I32Shl: foldI32(left, right, I32Shl);
			case I32ShrS: foldI32(left, right, I32ShrS);
			case I32ShrU: foldI32(left, right, I32ShrU);
			case I32Eq: foldI32(left, right, I32Eq);
			case I32LtS: foldI32(left, right, I32LtS);
			case I32LeS: foldI32(left, right, I32LeS);
			case F64Add: foldF64(left, right, F64Add);
			case F64Sub: foldF64(left, right, F64Sub);
			case F64Mul: foldF64(left, right, F64Mul);
			case F64Div: foldF64(left, right, F64Div);
			case F64Eq: foldF64(left, right, F64Eq);
			case F64Lt: foldF64(left, right, F64Lt);
			case F64Le: foldF64(left, right, F64Le);
			default: null;
		};
	}

	static function foldI32(left:WasmInstruction, right:WasmInstruction, operation:WasmInstruction):Null<WasmInstruction> {
		return switch left {
			case I32Const(a):
				switch right {
					case I32Const(b):
						switch operation {
							case I32Add: I32Const(a + b);
							case I32Sub: I32Const(a - b);
							case I32Mul: I32Const(a * b);
							case I32And: I32Const(a & b);
							case I32Xor: I32Const(a ^ b);
							case I32Or: I32Const(a | b);
							case I32Shl: I32Const(a << (b & 31));
							case I32ShrS: I32Const(a >> (b & 31));
							case I32ShrU: I32Const(a >>> (b & 31));
							case I32Eq: I32Const(a == b ? 1 : 0);
							case I32LtS: I32Const(a < b ? 1 : 0);
							case I32LeS: I32Const(a <= b ? 1 : 0);
							default: null;
						};
					default: null;
				}
			default: null;
		};
	}

	static function foldF64(left:WasmInstruction, right:WasmInstruction, operation:WasmInstruction):Null<WasmInstruction> {
		return switch left {
			case F64Const(a):
				switch right {
					case F64Const(b):
						switch operation {
							case F64Add: F64Const(a + b);
							case F64Sub: F64Const(a - b);
							case F64Mul: F64Const(a * b);
							case F64Div if (b != 0): F64Const(a / b);
							case F64Eq: I32Const(a == b ? 1 : 0);
							case F64Lt: I32Const(a < b ? 1 : 0);
							case F64Le: I32Const(a <= b ? 1 : 0);
							default: null;
						};
					default: null;
				}
			default: null;
		};
	}
}

private enum PairRewrite {
	RemovePair;
	ReplacePair(instruction:WasmInstruction);
}
