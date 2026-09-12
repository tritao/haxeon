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

typedef WasmAnalysisVisitor = IrFunction->Array<WasmSafepoint>->Void;

/** Computes precise managed-reference roots from SSA liveness at safepoints. */
class WasmGcRoots {
	public static inline final SECTION_VERSION:Int = 1;

	public static function analyze(fn:IrFunction):Array<WasmSafepoint> {
		var graph = new IrGraph(fn),
			referenceIds:Array<Int> = [],
			seenReferences:Map<Int, Bool> = [];
		for (argument in fn.arguments)
			addReferenceId(referenceIds, seenReferences, argument);
		for (block in fn.blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null)
					addReferenceId(referenceIds, seenReferences, output);
			}
		referenceIds.sort(function(left, right) return left - right);
		var referenceIndices:Map<Int, Int> = [];
		for (index in 0...referenceIds.length)
			referenceIndices.set(referenceIds[index], index);
		var wordCount = (referenceIds.length + 31) >> 5,
			liveIn:Map<Int, Array<Int>> = [],
			liveOut:Map<Int, Array<Int>> = [];
		for (id in graph.order) {
			liveIn.set(id, emptyBitSet(wordCount));
			liveOut.set(id, emptyBitSet(wordCount));
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (position in 0...graph.order.length) {
				var id = graph.order[graph.order.length - 1 - position],
					out = emptyBitSet(wordCount);
				for (successor in graph.successors.get(id))
					unionBitsInto(out, liveIn.get(successor));
				var current = out.copy(), block = graph.block(id);
				for (index in 0...block.instructions.length) {
					var instruction = block.instructions[block.instructions.length - 1 - index].value,
						output = IrOperands.output(instruction);
					if (output != null && WasmTarget.isReference(output.type))
						clearBit(current, requiredIndex(referenceIndices, output.id));
					for (input in IrOperands.inputs(instruction))
						if (WasmTarget.isReference(input.type))
							setBit(current, requiredIndex(referenceIndices, input.id));
				}
				if (!sameBitSet(out, liveOut.get(id)) || !sameBitSet(current, liveIn.get(id))) {
					liveOut.set(id, out);
					liveIn.set(id, current);
					changed = true;
				}
			}
		}
		var result:Array<WasmSafepoint> = [];
		for (id in graph.order) {
			var block = graph.block(id), current = liveOut.get(id).copy();
			for (index in 0...block.instructions.length) {
				var instruction = block.instructions[block.instructions.length - 1 - index].value;
				var output = IrOperands.output(instruction);
				if (output != null && WasmTarget.isReference(output.type))
					clearBit(current, requiredIndex(referenceIndices, output.id));
				for (input in IrOperands.inputs(instruction))
					if (WasmTarget.isReference(input.type))
						setBit(current, requiredIndex(referenceIndices, input.id));
				if (isSafepoint(instruction))
					result.push({block: id, instruction: block.instructions.length - 1 - index, liveReferences: liveReferenceIds(current, referenceIds)});
			}
		}
		result.sort(function(left, right) return left.block == right.block ? left.instruction - right.instruction : left.block - right.block);
		return result;
	}

	/** Stable root metadata consumed by a future precise Wasm collector. */
	public static function encode(program:IrProgram):Bytes
		return encodeAndVisit(program);

	/** Encodes root metadata and lets the caller consume each function analysis before moving on. */
	public static function encodeAndVisit(program:IrProgram, ?visit:WasmAnalysisVisitor):Bytes {
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
			if (visit != null)
				visit(fn, points);
		}
		return output.getBytes();
	}

	static function isSafepoint(instruction:IrInstruction):Bool
		return switch instruction {
			case Call(_, _, _), CNativeCall(_, _, _), CallClosure(_, _, _), MethodCall(_, _, _, _), NewObject(_, _), InstanceClosure(_, _, _),
				MakeEnum(_, _, _, _), IteratorNew(_, _), BeginTry(_, _): true;
			case ToDyn(_, value):
				switch value.type {
					case I32, Bool, I64, F64: true;
					default: false;
				};
			default: false;
		};

	static function addReferenceId(ids:Array<Int>, seen:Map<Int, Bool>, value:IrValue):Void {
		if (WasmTarget.isReference(value.type) && !seen.exists(value.id)) {
			seen.set(value.id, true);
			ids.push(value.id);
		}
	}

	static function emptyBitSet(wordCount:Int):Array<Int>
		return [for (_ in 0...wordCount) 0];

	static function unionBitsInto(target:Array<Int>, source:Array<Int>):Void
		for (index in 0...target.length)
			target[index] |= source[index];

	static function sameBitSet(left:Array<Int>, right:Array<Int>):Bool {
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}

	static inline function setBit(set:Array<Int>, index:Int):Void
		set[index >> 5] |= 1 << (index & 31);

	static inline function clearBit(set:Array<Int>, index:Int):Void
		set[index >> 5] &= ~(1 << (index & 31));

	static inline function hasBit(set:Array<Int>, index:Int):Bool
		return set[index >> 5] & (1 << (index & 31)) != 0;

	static function liveReferenceIds(set:Array<Int>, ids:Array<Int>):Array<Int> {
		var result = [];
		for (index in 0...ids.length)
			if (hasBit(set, index))
				result.push(ids[index]);
		return result;
	}

	static function requiredIndex(indices:Map<Int, Int>, valueId:Int):Int {
		if (!indices.exists(valueId))
			throw 'Missing Wasm GC-root index for value $valueId';
		return indices.get(valueId);
	}
}
