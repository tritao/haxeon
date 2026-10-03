package compiler.backend.wasm;

import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmTypes.WasmInstruction;

/**
 * `Math` remainder (`%` on Floats) as plain Wasm, so it needs no host import. It is C's `fmod`: the result is exact,
 * takes the sign of the dividend, and is NaN for a zero divisor, an infinite dividend or a NaN operand.
 *
 * Binary long division on magnitudes: double the divisor to the largest multiple of it that fits, then walk back down,
 * subtracting each multiple that fits. Scaling by two and subtracting a value of at most the same magnitude are both
 * exact, so no rounding ever happens.
 *
 * Whole numbers below 2^53 take a shortcut, since that is what generators and counters feed it: the quotient is
 * within one of `floor(x / y)`, every product is a whole number no larger than the dividend plus the divisor, so
 * `x - quotient * y` is exact and a single correction step settles it.
 */
class WasmFmod {
	/** Locals after the two parameters: dividend magnitude, divisor magnitude, scaled divisor, dividend is negative. */
	public static function locals():Array<WasmLocal>
		return [{type: F64}, {type: F64}, {type: F64}, {type: I32}];

	public static function body():Array<WasmInstruction> {
		var dividend = 0, divisor = 1, remainder = 2, magnitude = 3, scaled = 4, negative = 5;
		var infinity = Math.POSITIVE_INFINITY;
		function returnNaN():Array<WasmInstruction>
			return [F64Const(0), F64Const(0), F64Div, Return];
		function guard(condition:Array<WasmInstruction>, result:Array<WasmInstruction>):Array<WasmInstruction>
			return condition.concat([If(null)]).concat(result).concat([End]);
		return guard([LocalGet(dividend), LocalGet(dividend), F64Eq, I32Eqz],
			returnNaN()).concat(guard([LocalGet(divisor), LocalGet(divisor), F64Eq, I32Eqz], returnNaN()))
			.concat([
				LocalGet(dividend),
				F64Const(0),
				F64Lt,
				LocalSet(negative),
				LocalGet(dividend),
				LocalSet(remainder),
				LocalGet(negative),
				If(null),
				LocalGet(dividend),
				F64Const(-1),
				F64Mul,
				LocalSet(remainder),
				End,
				LocalGet(divisor),
				LocalSet(magnitude),
				LocalGet(divisor),
				F64Const(0),
				F64Lt,
				If(null),
				LocalGet(divisor),
				F64Const(-1),
				F64Mul,
				LocalSet(magnitude),
				End
			])
			.concat(guard([LocalGet(magnitude), F64Const(0), F64Eq], returnNaN()))
			.concat(guard([LocalGet(remainder), F64Const(infinity), F64Eq], returnNaN()))
			.concat(guard([LocalGet(magnitude), F64Const(infinity), F64Eq], [LocalGet(dividend), Return]))
			.concat(guard([LocalGet(remainder), LocalGet(magnitude), F64Lt], [LocalGet(dividend), Return]))
			.concat(guard([
				LocalGet(remainder),
				F64Const(9007199254740992.0),
				F64Lt,
				LocalGet(remainder),
				LocalGet(remainder),
				F64Floor,
				F64Eq,
				I32And,
				LocalGet(magnitude),
				LocalGet(magnitude),
				F64Floor,
				F64Eq,
				I32And
			], [
				LocalGet(remainder),
				LocalGet(remainder),
				LocalGet(magnitude),
				F64Div,
				F64Floor,
				LocalGet(magnitude),
				F64Mul,
				F64Sub,
				LocalSet(scaled),
				// the rounded quotient may have been one too high or one too low
				LocalGet(scaled),
				F64Const(0),
				F64Lt,
				If(null),
				LocalGet(scaled),
				LocalGet(magnitude),
				F64Add,
				LocalSet(scaled),
				End,
				LocalGet(scaled),
				LocalGet(magnitude),
				F64Lt,
				I32Eqz,
				If(null),
				LocalGet(scaled),
				LocalGet(magnitude),
				F64Sub,
				LocalSet(scaled),
				End,
				LocalGet(scaled),
				LocalGet(negative),
				If(F64),
				F64Const(-1),
				Else,
				F64Const(1),
				End,
				F64Mul,
				Return
			]))
			.concat([
				// scale up: the largest divisor * 2^k not above the dividend
				LocalGet(magnitude),
				LocalSet(scaled),
				Block(null),
				Loop(null),
				LocalGet(scaled),
				F64Const(2),
				F64Mul,
				LocalGet(remainder),
				F64Le,
				I32Eqz,
				BrIf(1),
				LocalGet(scaled),
				F64Const(2),
				F64Mul,
				LocalSet(scaled),
				Br(0),
				End,
				End,
				// walk back down, subtracting each multiple that fits
				Block(null),
				Loop(null),
				LocalGet(remainder),
				LocalGet(scaled),
				F64Lt,
				I32Eqz,
				If(null),
				LocalGet(remainder),
				LocalGet(scaled),
				F64Sub,
				LocalSet(remainder),
				End,
				LocalGet(scaled),
				LocalGet(magnitude),
				F64Eq,
				BrIf(1),
				LocalGet(scaled),
				F64Const(0.5),
				F64Mul,
				LocalSet(scaled),
				Br(0),
				End,
				End,
				// the sign of the dividend, which also makes an exact multiple -0.0 for a negative dividend
				LocalGet(remainder),
				LocalGet(negative),
				If(F64),
				F64Const(-1),
				Else,
				F64Const(1),
				End,
				F64Mul,
				Return
			]);
	}
}
