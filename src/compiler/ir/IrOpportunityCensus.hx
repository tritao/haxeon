package compiler.ir;

import compiler.ir.Ir;

private typedef CensusLoop = {final header:Int; final members:Map<Int, Bool>;}
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
		for (fn in program.functions) {
			var row = inspect(fn);
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

	static function inspect(fn:IrFunction):CensusRow {
		var graph = new IrGraph(fn),
			loops = naturalLoops(graph),
			definitions:Map<Int, IrInstruction> = [],
			homes:Map<Int, Int> = [];
		for (block in fn.blocks)
			for (located in block.instructions) {
				var out = IrOperands.output(located.value);
				if (out != null) {
					definitions.set(out.id, located.value);
					homes.set(out.id, block.id);
				}
			}
		var counts:Array<Int> = [for (_ in labels) 0],
			weighted:Array<Float> = [for (_ in labels) 0.0];
		for (block in fn.blocks) {
			var depth = 0;
			for (loop in loops)
				if (loop.members.exists(block.id))
					depth++;
			var weight = Math.pow(8, depth), seen:Map<String, Bool> = [];
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
						for (loop in loops)
							if (loop.members.exists(block.id) && counted(loop, graph, definitions, array, index)) {
								count(2);
								break;
							}
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
				if (pureArithmetic(instruction) && depth > 0)
					for (loop in loops)
						if (loop.members.exists(block.id)) {
							var invariant = true;
							for (input in IrOperands.inputs(instruction))
								if (!outsideOrConstant(input, loop, homes, definitions))
									invariant = false;
							if (invariant) {
								count(7);
								break;
							}
						}
				switch instruction {
					case Div(_, _, divisor), Mod(_, _, divisor):
						var value:Null<Float> = switch definitions.get(divisor.id) {
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

	static function naturalLoops(graph:IrGraph):Array<CensusLoop> {
		var loops:Array<CensusLoop> = [];
		for (tail in graph.order)
			for (header in graph.successors.get(tail))
				if (graph.dominates(header, tail)) {
					var found:Null<CensusLoop> = null;
					for (loop in loops)
						if (loop.header == header)
							found = loop;
					if (found == null) {
						found = {header: header, members: []};
						loops.push(found);
					}
					found.members.set(header, true);
					var pending:Array<Int> = [tail];
					while (pending.length > 0) {
						var id = pending.pop();
						if (found.members.exists(id))
							continue;
						found.members.set(id, true);
						for (pred in graph.predecessors.get(id))
							pending.push(pred);
					}
				}
		return loops;
	}

	static function outsideOrConstant(input:IrValue, loop:CensusLoop, homes:Map<Int, Int>, definitions:Map<Int, IrInstruction>):Bool {
		var home = homes.get(input.id);
		if (home == null || !loop.members.exists(home))
			return true;
		return switch definitions.get(input.id) {
			case ConstInt(_, _), ConstFloat(_, _), ConstBool(_, _): true;
			default: false;
		};
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

	/** Strict canonical zero-start, unit-step phi, bounded by this array's length; unknown calls reject the loop. */
	static function counted(loop:CensusLoop, graph:IrGraph, definitions:Map<Int, IrInstruction>, array:IrValue, index:IrValue):Bool {
		var inputs = switch definitions.get(index.id) {
			case Phi(_, incoming): incoming;
			default: return false;
		};
		var start = false, step = false, bound = false;
		for (incoming in inputs)
			if (!loop.members.exists(incoming.block)) {
				switch definitions.get(incoming.value.id) {
					case ConstInt(_, 0):
						start = true;
					default:
						return false;
				}
			} else {
				switch definitions.get(incoming.value.id) {
					case Add(_, a, b) if (a.id == index.id):
						switch definitions.get(b.id) {
							case ConstInt(_, 1): step = true;
							default: return false;
						}
					default:
						return false;
				}
			}
		for (id in graph.order)
			if (loop.members.exists(id)) {
				var block = graph.block(id);
				for (located in block.instructions)
					switch located.value {
						case Call(_, _, _), CNativeCall(_, _, _), CallClosure(_, _, _), MethodCall(_, _, _, _), MemoryStore(_, _, _), ArraySet(_, _, _):
							return false;
						default:
					}
				if (id == loop.header && block.terminator != null)
					switch block.terminator.value {
						case Branch(condition, yes, no) if (loop.members.exists(yes) && !loop.members.exists(no)):
							switch definitions.get(condition.id) {
								case Less(_, a, b) if (a.id == index.id):
									switch definitions.get(b.id) {
										case ArraySize(_, receiver) if (receiver.id == array.id): bound = true;
										default:
									}
								default:
							}
						default:
					}
			}
		return start && step && bound;
	}
}
