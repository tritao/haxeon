package compiler.backend.wasm;

import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmHeapType;
import compiler.ir.Ir.IrType;
import compiler.ir.IrFunction;
import compiler.ir.IrOperands;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrTerminator;

private typedef WasmInterval = {
	final valueId:Int;
	final type:WasmValueType;
	final start:Int;
	final end:Int;
}

private typedef WasmLocalInterval = {
	final local:Int;
	var end:Int;
	final type:WasmValueType;
}

/** First value-placement pass: stable SSA values become coalescible Wasm locals. */
class WasmValuePlacement {
	public final values:Map<Int, Int> = [];
	public final locals:Array<WasmLocal> = [];

	var nextLocal:Int;

	public function new(fn:IrFunction) {
		var intervals:Array<WasmInterval> = [], starts:Map<Int, Int> = [], ends:Map<Int, Int> = [], position = 0;
		for (index in 0...fn.arguments.length)
			values.set(fn.arguments[index].id, index);
		nextLocal = fn.arguments.length;
		// Linear intervals cannot represent values that remain live across CFG
		// edges or phi operands. Keep blockful functions uncoalesced until a
		// CFG-aware interference analysis can prove those values do not overlap.
		if (fn.blocks.length > 1) {
			for (block in fn.blocks)
				for (located in block.instructions) {
					var output = IrOperands.output(located.value);
					if (output != null && output.type != Void && !values.exists(output.id)) {
						values.set(output.id, nextLocal++);
						locals.push({type: WasmBackend.requireValueType(output.type)});
					}
				}
			return;
		}
		for (argument in fn.arguments) {
			starts.set(argument.id, 0);
			ends.set(argument.id, 0);
		}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				for (input in IrOperands.inputs(located.value))
					if (WasmTarget.isReference(input.type) || input.type != IrType.Void)
						ends.set(input.id, position);
				switch located.value {
					case Phi(_, inputs):
						for (input in inputs)
							ends.set(input.value.id, position);
					default:
				}
				var output = IrOperands.output(located.value);
				if (output != null && output.type != Void && !starts.exists(output.id)) {
					starts.set(output.id, position);
					ends.set(output.id, position);
				}
				position++;
			}
			if (block.terminator != null) {
				for (input in terminatorInputs(block.terminator.value))
					ends.set(input.id, position);
				position++;
			}
		}
		for (block in fn.blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null && output.type != Void && starts.exists(output.id))
					intervals.push({
						valueId: output.id,
						type: WasmBackend.requireValueType(output.type),
						start: requiredPosition(starts, output.id),
						end: requiredPosition(ends, output.id)
					});
			}
		intervals.sort(function(left, right) return left.start == right.start ? left.valueId - right.valueId : left.start - right.start);
		var active:Array<WasmLocalInterval> = [];
		for (interval in intervals) {
			var reusable:Null<WasmLocalInterval> = null;
			for (candidate in active)
				if (candidate.end < interval.start
					&& sameValueType(candidate.type, interval.type)
					&& (reusable == null || candidate.end < reusable.end))
					reusable = candidate;
			var local:Int;
			if (reusable != null) {
				local = reusable.local;
				reusable.end = interval.end;
			} else {
				local = nextLocal++;
				locals.push({type: interval.type});
				active.push({local: local, end: interval.end, type: interval.type});
			}
			values.set(interval.valueId, local);
		}
	}

	public function allocate(type:WasmValueType):Int {
		var result = nextLocal++;
		locals.push({type: type});
		return result;
	}

	public function local(valueId:Int):Int {
		if (!values.exists(valueId))
			throw 'Wasm value $valueId has no placement';
		return requiredPosition(values, valueId);
	}

	static function terminatorInputs(terminator:IrTerminator):Array<compiler.ir.Ir.IrValue>
		return switch terminator {
			case Return(value), Throw(value), Rethrow(value): [value];
			case Jump(_): [];
			case Branch(condition, _, _): [condition];
		};

	static function requiredPosition(values:Map<Int, Int>, valueId:Int):Int {
		if (!values.exists(valueId))
			throw 'Missing Wasm value placement for $valueId';
		return values.get(valueId);
	}

	static function sameValueType(left:WasmValueType, right:WasmValueType):Bool
		return switch [left, right] {
			case [I32, I32], [I64, I64], [F32, F32], [F64, F64]: true;
			case [Ref(leftType), Ref(rightType)]: leftType.nullable == rightType.nullable && sameHeapType(leftType.heap, rightType.heap);
			default: false;
		};

	static function sameHeapType(left:WasmHeapType, right:WasmHeapType):Bool {
		return switch [left, right] {
			case [Any, Any], [Eq, Eq], [I31, I31], [Struct, Struct], [Array, Array], [Func, Func], [Extern, Extern], [None, None], [NoExtern, NoExtern],
				[NoFunc, NoFunc], [Exn, Exn], [NoExn, NoExn]: true;
			case [Type(leftIndex), Type(rightIndex)]: leftIndex == rightIndex;
			default: false;
		};
	}
}
