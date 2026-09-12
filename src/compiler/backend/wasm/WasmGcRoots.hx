package compiler.backend.wasm;

import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrValue;
import compiler.ir.IrOperands;
import compiler.ir.IrFunction;
import compiler.ir.IrGraph;
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import compiler.ir.codec.IrTypeCodec;
import compiler.ir.Ir.IrProgram;

typedef WasmSafepoint = {
	final block:Int;
	final instruction:Int;
	final liveReferences:Array<Int>;
}

/** Computes precise managed-reference roots from SSA liveness at safepoints. */
class WasmGcRoots {
	public static inline final SECTION_VERSION:Int = 1;

	public static function analyze(fn:IrFunction):Array<WasmSafepoint> {
		var graph = new IrGraph(fn),
			liveIn:Map<Int, Map<Int, Bool>> = [],
			liveOut:Map<Int, Map<Int, Bool>> = [];
		for (id in graph.order) {
			liveIn.set(id, []);
			liveOut.set(id, []);
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (position in 0...graph.order.length) {
				var id = graph.order[graph.order.length - 1 - position],
					out:Map<Int, Bool> = [];
				for (successor in graph.successors.get(id))
					unionInto(out, liveIn.get(successor));
				var current = copySet(out), block = graph.block(id);
				for (index in 0...block.instructions.length) {
					var instruction = block.instructions[block.instructions.length - 1 - index].value,
						output = IrOperands.output(instruction);
					if (output != null && WasmTarget.isReference(output.type))
						current.remove(output.id);
					for (input in IrOperands.inputs(instruction))
						if (WasmTarget.isReference(input.type))
							current.set(input.id, true);
				}
				if (!sameSet(out, liveOut.get(id)) || !sameSet(current, liveIn.get(id))) {
					liveOut.set(id, out);
					liveIn.set(id, current);
					changed = true;
				}
			}
		}
		var result:Array<WasmSafepoint> = [];
		for (id in graph.order) {
			var block = graph.block(id), current = copySet(liveOut.get(id));
			for (index in 0...block.instructions.length) {
				var instruction = block.instructions[block.instructions.length - 1 - index].value;
				var output = IrOperands.output(instruction);
				if (output != null && WasmTarget.isReference(output.type))
					current.remove(output.id);
				for (input in IrOperands.inputs(instruction))
					if (WasmTarget.isReference(input.type))
						current.set(input.id, true);
				if (isSafepoint(instruction))
					result.push({block: id, instruction: block.instructions.length - 1 - index, liveReferences: sorted(current)});
			}
		}
		result.sort(function(left, right) return left.block == right.block ? left.instruction - right.instruction : left.block - right.block);
		return result;
	}

	/** Stable root metadata consumed by a future precise Wasm collector. */
	public static function encode(program:IrProgram):Bytes {
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("HGR");
		output.writeByte(SECTION_VERSION);
		output.writeInt32(program.functions.length);
		for (fn in program.functions) {
			IrTypeCodec.writeString(output, fn.name);
			var points = analyze(fn);
			output.writeInt32(points.length);
			for (point in points) {
				output.writeInt32(point.block);
				output.writeInt32(point.instruction);
				output.writeInt32(point.liveReferences.length);
				for (value in point.liveReferences)
					output.writeInt32(value);
			}
		}
		return output.getBytes();
	}

	static function isSafepoint(instruction:IrInstruction):Bool
		return switch instruction {
			case Call(_, _, _), CNativeCall(_, _, _), CallClosure(_, _, _), MethodCall(_, _, _, _), NewObject(_, _), InstanceClosure(_, _, _),
				MakeEnum(_, _, _, _), BeginTry(_, _): true;
			case ToDyn(_, value):
				switch value.type {
					case I32, Bool, I64, F64: true;
					default: false;
				};
			default: false;
		};

	static function sorted(set:Map<Int, Bool>):Array<Int> {
		var result = [for (key in set.keys()) key];
		result.sort(function(left, right) return left - right);
		return result;
	}

	static function copySet(set:Map<Int, Bool>):Map<Int, Bool> {
		var result:Map<Int, Bool> = [];
		unionInto(result, set);
		return result;
	}

	static function unionInto(target:Map<Int, Bool>, source:Map<Int, Bool>):Void
		for (key in source.keys())
			target.set(key, true);

	static function sameSet(left:Map<Int, Bool>, right:Map<Int, Bool>):Bool {
		for (key in left.keys())
			if (!right.exists(key))
				return false;
		for (key in right.keys())
			if (!left.exists(key))
				return false;
		return true;
	}
}
