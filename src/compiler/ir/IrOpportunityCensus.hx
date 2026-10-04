package compiler.ir;

import compiler.ir.Ir;

private typedef CensusAllocation = {final value:Int; final type:String; final local:Bool; final reason:String;}
private typedef CensusRow = {final name:String; final counts:Array<Int>; final weighted:Array<Float>; final allocations:Array<CensusAllocation>;}

/** Read-only post-pass census. Weights are static 8^natural-loop-depth, not measured execution counts. */
class IrOpportunityCensus {
	static final labels:Array<String> = [
		"arrayReads",
		"arrayWrites",
		"countedAccesses",
		"repeatedLoads",
		"loopConversions",
		"allocations",
		"localAllocations",
		"loopInvariantComputations",
		"constantDivMod"
	];

	public static function report(program:IrProgram, ?allowInline:Bool):Void {
		if (Sys.getEnv("HAXEON_IR_CENSUS") != "1")
			return;
		var rows:Array<CensusRow> = [],
			totals:Array<Int> = [for (_ in labels) 0],
			weights:Array<Float> = [for (_ in labels) 0.0];
		var pureCalls = IrLoopBounds.pureNativeCalls(program.natives),
			objects:Map<String, IrObject> = [];
		for (object in program.objects)
			objects.set(object.name, object);
		var inlineMode = allowInline == null ? IrInliner.enabled : allowInline;
		for (fn in program.functions) {
			var row = inspect(fn, pureCalls, objects, inlineMode);
			rows.push(row);
			for (i in 0...labels.length) {
				totals[i] += row.counts[i];
				weights[i] += row.weighted[i];
			}
		}
		rows.sort(function(a, b) return Reflect.compare(a.name, b.name));
		for (row in rows)
			Sys.stderr().writeString("IR_CENSUS " + haxe.Json.stringify(row) + "\n");
		Sys.stderr().writeString("IR_CENSUS " + haxe.Json.stringify({
			name: "TOTAL",
			labels: labels,
			counts: totals,
			weighted: weights
		}) + "\n");
	}

	static function inspect(fn:IrFunction, pureCalls:Map<String, Bool>, objects:Map<String, IrObject>, allowInline:Bool):CensusRow {
		var bounds = new IrLoopBounds(fn, pureCalls),
			allocations:Array<CensusAllocation> = [];
		var counts:Array<Int> = [for (_ in labels) 0],
			weighted:Array<Float> = [for (_ in labels) 0.0];
		for (block in fn.blocks) {
			var depth = bounds.depth(block.id),
				weight = Math.pow(8, depth),
				seen:Map<String, Bool> = [];
			var count = function(category:Int):Void {
				counts[category]++;
				weighted[category] += weight;
			};
			for (located in block.instructions) {
				var instruction = located.value;
				switch instruction {
					case ArrayGet(_, array, index), ArraySet(array, index, _):
						count(switch instruction {
							case ArrayGet(_, _, _): 0;
							default: 1;
						});
						if (bounds.proven(array, index, block.id))
							count(2);
					case ToDyn(_, _), SafeCast(_, _), ToVirtual(_, _), IntToFloat(_, _), FloatToInt(_, _), IntToInt64(_, _):
						if (depth > 0)
							count(4);
					case NewObject(out, _):
						count(5);
						if (localUses(fn, out))
							count(6);
						allocations.push(allocationInfo(fn, out, objects, allowInline));
					case Call(out, name, _) if (StringTools.startsWith(name, "__array_alloc_")):
						count(5);
						if (localUses(fn, out))
							count(6);
						allocations.push(allocationInfo(fn, out, objects, allowInline));
					default:
				}
				if ((pureArithmetic(instruction) && bounds.invariantInputs(instruction, block.id))
					|| constantField(fn, bounds, instruction, block.id, pureCalls))
					count(7);
				switch instruction {
					case Div(_, _, divisor), Mod(_, _, divisor):
						var value:Null<Float> = switch bounds.definition(divisor.id) {
							case ConstInt(_, n): n;
							case ConstFloat(_, n): n;
							default: null;
						};
						if (value != null && value != 0 && !isPowerOfTwo(value))
							count(8);
					default:
				}
				// Conservative block-local duplicate scan: any store or code-running operation clears all facts.
				var key:Null<String> = switch instruction {
					case FieldGet(_, object, field): "f:" + object.id + ":" + field;
					case ArrayGet(_, array, index): "a:" + array.id + ":" + index.id;
					default: null;
				};
				if (key != null) {
					if (seen.exists(key))
						count(3);
					seen.set(key, true);
				}
				switch instruction {
					case Call(_, _, _), CNativeCall(_, _, _), CallClosure(_, _, _), MethodCall(_, _, _, _), FieldSet(_, _, _), ArraySet(_, _, _),
						MemoryStore(_, _, _), GlobalSet(_, _), BeginTry(_, _), EndTry(_), Catch(_), SafeCast(_, _), ToDyn(_, _), ToVirtual(_, _):
						seen = [];
					default:
				}
			}
		}
		return {
			name: fn.name,
			counts: counts,
			weighted: weighted,
			allocations: allocations
		};
	}

	static function pureArithmetic(instruction:IrInstruction):Bool {
		return switch instruction {
			case Add(_, _, _), Sub(_, _, _), Mul(_, _, _), Div(_, _, _), Mod(_, _, _), BitAnd(_, _, _), BitOr(_, _, _), BitXor(_, _, _), ShiftLeft(_, _, _),
				ShiftRight(_, _, _), UnsignedShiftRight(_, _, _), Less(_, _, _), LessEqual(_, _, _), Equal(_, _, _): true;
			default: false;
		};
	}

	/** Finite normal and subnormal powers, regardless of reciprocal eligibility. */
	static function isPowerOfTwo(value:Float):Bool {
		var bits = haxe.io.Bytes.alloc(8);
		bits.setDouble(0, value);
		var rawHigh = bits.getInt32(4), low = bits.getInt32(0);
		var exponent = (rawHigh >>> 20) & 2047, high = rawHigh & 1048575;
		if (exponent == 2047)
			return false;
		if (exponent != 0)
			return high == 0 && low == 0;
		return high != 0 ? low == 0 && (high & (high - 1)) == 0 : low != 0 && (low & (low - 1)) == 0;
	}

	/** Count only a constant scalar field of a fresh, unpublished object, initialized outside every loop. */
	static function constantField(fn:IrFunction, bounds:IrLoopBounds, instruction:IrInstruction, at:Int, pureCalls:Map<String, Bool>):Bool {
		if (bounds.depth(at) == 0)
			return false;
		var receiver:IrValue, field:String;
		switch instruction {
			case FieldGet(output, object, name):
				switch output.type {
					case I32, F64, Bool:
					default: return false;
				}
				receiver = object;
				field = name;
			default:
				return false;
		}
		switch bounds.definition(receiver.id) {
			case NewObject(_, _):
			default:
				return false;
		}
		if (!localUses(fn, receiver))
			return false;
		var writes = 0, initialized:Null<Int> = null;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case FieldSet(object, name, value) if (object.id == receiver.id && name == field):
						writes++;
						switch bounds.definition(value.id) {
							case ConstInt(_, _), ConstFloat(_, _), ConstBool(_, _), ConstString(_, _): initialized = block.id;
							default: return false;
						}
					case Call(_, name, _) if (pureCalls.exists(name)):
					case Call(_, _, _), CNativeCall(_, _, _), MethodCall(_, _, _, _), CallClosure(_, _, _), MemoryStore(_, _, _), BeginTry(_, _), EndTry(_),
						Catch(_):
						return false;
					default:
				}
		return writes == 1 && initialized != null && bounds.depth(initialized) == 0 && bounds.dominates(initialized, at);
	}

	static function allocationInfo(fn:IrFunction, value:IrValue, objects:Map<String, IrObject>, allowInline:Bool):CensusAllocation {
		var escape = localUseFailure(fn, value), local = escape == null;
		var kind = switch value.type {
			case Array(_): "arrays are not scalar-replacement candidates";
			case Obj(name):
				var object = objects.get(name);
				if (object == null) "object layout unavailable"; else if (!object.isValue) "ordinary heap objects are not scalar-replacement candidates"; else
					if (!allowInline) "scalar replacement does not run with inlining disabled"; else {
					var nested = false, handlers = false;
					for (field in object.fields)
						switch field.type {
							case Obj(child) if (objects.exists(child) && objects.get(child).isValue): nested = true;
							default:
						}
					for (block in fn.blocks)
						for (located in block.instructions)
							switch located.value {
								case BeginTry(_, _), EndTry(_), Catch(_): handlers = true;
								default:
							}
					if (nested)
						"inline value-class fields prevent scalar replacement";
					else if (!local)
						"non-field use prevents scalar replacement";
					else if (handlers)
						"handler regions restrict scalar replacement to single-block objects";
					else
						"remaining value-class candidate requires inspection";
				}
			default: "unsupported allocation type";
		};
		return {
			value: value.id,
			type: Std.string(value.type),
			local: local,
			reason: kind + (escape == null ? "" : "; locality not proven: " + escape)
		};
	}

	static function constructorName(value:String):String {
		var end = value.indexOf("(");
		return end < 0 ? value : value.substr(0, end);
	}

	static function localUses(fn:IrFunction, value:IrValue):Bool
		return localUseFailure(fn, value) == null;

	/** Direct field/element uses remain local; report the first unsupported use in instruction order. */
	static function localUseFailure(fn:IrFunction, value:IrValue):Null<String> {
		for (block in fn.blocks) {
			for (located in block.instructions) {
				switch located.value {
					case Phi(_, inputs):
						for (input in inputs)
							if (input.value.id == value.id)
								return "phi alias";
					default:
				}
				for (input in IrOperands.inputs(located.value))
					if (input.id == value.id)
						switch located.value {
							case FieldGet(_, object, _) if (object.id == value.id):
							case FieldSet(object, _, stored) if (object.id == value.id && stored.id != value.id):
							case ArrayGet(_, array, index) if (array.id == value.id && index.id != value.id):
							case ArraySet(array, index, stored) if (array.id == value.id && index.id != value.id && stored.id != value.id):
							case ArraySize(_, array) if (array.id == value.id):
							default:
								return constructorName(Std.string(located.value));
						}
			}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(v), Throw(v), Rethrow(v), Branch(v, _, _) if (v.id == value.id):
						return constructorName(Std.string(block.terminator.value));
					default:
				}
		}
		return null;
	}
}
