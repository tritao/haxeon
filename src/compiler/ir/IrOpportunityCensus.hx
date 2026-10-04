package compiler.ir;

import compiler.ir.Ir;

private typedef CensusRow = {final name:String; final counts:Array<Int>; final weighted:Array<Float>;}

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
		"loopInvariantArithmetic",
		"constantDivMod"
	];

	public static function report(program:IrProgram):Void {
		if (Sys.getEnv("HAXEON_IR_CENSUS") != "1")
			return;
		var rows:Array<CensusRow> = [],
			totals:Array<Int> = [for (_ in labels) 0],
			weights:Array<Float> = [for (_ in labels) 0.0];
		var pureCalls = IrLoopBounds.pureNativeCalls(program.natives);
		for (fn in program.functions) {
			var row = inspect(fn, pureCalls);
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

	static function inspect(fn:IrFunction, pureCalls:Map<String, Bool>):CensusRow {
		var bounds = new IrLoopBounds(fn, pureCalls);
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
					case Call(out, name, _) if (StringTools.startsWith(name, "__array_alloc_")):
						count(5);
						if (localUses(fn, out))
							count(6);
					default:
				}
				if (pureArithmetic(instruction) && bounds.invariantInputs(instruction, block.id))
					count(7);
				switch instruction {
					case Div(_, _, divisor), Mod(_, _, divisor):
						var value:Null<Float> = switch bounds.definition(divisor.id) {
							case ConstInt(_, n): n;
							case ConstFloat(_, n): n;
							default: null;
						};
						if (value != null && value != 0 && !IrStrengthReduction.exactNormalReciprocal(value))
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
		return {name: fn.name, counts: counts, weighted: weighted};
	}

	static function pureArithmetic(instruction:IrInstruction):Bool {
		return switch instruction {
			case Add(_, _, _), Sub(_, _, _), Mul(_, _, _), Div(_, _, _), Mod(_, _, _), BitAnd(_, _, _), BitOr(_, _, _), BitXor(_, _, _), ShiftLeft(_, _, _),
				ShiftRight(_, _, _), UnsignedShiftRight(_, _, _), Less(_, _, _), LessEqual(_, _, _), Equal(_, _, _): true;
			default: false;
		};
	}

	/** Only direct field/element uses qualify. Phi, cast, argument, return and storing into another object escape. */
	static function localUses(fn:IrFunction, value:IrValue):Bool {
		for (block in fn.blocks) {
			for (located in block.instructions) {
				switch located.value {
					case Phi(_, inputs):
						for (input in inputs)
							if (input.value.id == value.id)
								return false;
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
								return false;
						}
			}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(v), Throw(v), Rethrow(v), Branch(v, _, _) if (v.id == value.id):
						return false;
					default:
				}
		}
		return true;
	}
}
