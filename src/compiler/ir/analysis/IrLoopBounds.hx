package compiler.ir.analysis;

import compiler.ir.analysis.IrBodyAnalysis.IrLoopForest;
import compiler.ir.cfg.IrBodyGraph;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrValueId;
import compiler.ir.names.IrReceiverCheck;
import compiler.ir.names.IrReferenceIdentity;
import compiler.ir.passes.scalars.IrScalarWordBits;

/**
 * Read-only proofs for unit-step counted loops, including the pre-increment form of counted for-in loops: an index that
 * starts at zero or more, counts up by one and is tested against an array's length before every access is in range of that
 * array, while nothing in the loop can resize an array. Read from a body's rows and its graph (`IrBodyGraph`), which the
 * caller has made. The loops are found when a proof first needs them, and the tables are kept from one body to the next
 * (`reset`), so a backend asks of every access at little cost.
 */
class IrLoopBounds {
	final pureCalls:Map<String, Bool>;
	var body:IrBody;
	var graph:IrBodyGraph;
	var loops:IrLoopForest;
	var loopsFound = false;

	/** By row, the id of the block that links it, or -1, once `rowsFound` (`homeOf`). */
	final rowBlocks:Array<Int> = [];

	var rowsFound = false;

	/** By loop, 1 when nothing in it may resize an array, 2 when something may, 0 until asked. */
	final stableLoops:Array<Int> = [];

	/** By value id, the `stamp` of the proof that has asked whether the value is nonnegative, so a cycle stops. */
	final seenValues:Array<Int> = [];

	/** By block id, the `stamp` of the walk that visited it (`unchangedSince`). */
	final seenBlocks:Array<Int> = [];

	final pending:Array<Int> = [];
	var stamp = 0;

	/** Where the induction variable `inductionStart` found starts: `startValue` plus `startOffset`. */
	var startValue = IrValueId.of(-1);

	var startOffset = 0;

	public function new(pureCalls:Map<String, Bool>) {
		this.pureCalls = pureCalls;
	}

	/** Starts reading `body`, whose graph `graph` is. */
	public function reset(body:IrBody, graph:IrBodyGraph):IrLoopBounds {
		this.body = body;
		this.graph = graph;
		loopsFound = false;
		rowsFound = false;
		return this;
	}

	/** The body's loops, found the first time they are asked for. */
	function forest():IrLoopForest {
		if (loopsFound)
			return loops;
		var known = new IrLoopForest(body, graph);
		loops = known;
		loopsFound = true;
		IrPassScratch.filledInts(stableLoops, known.count(), 0);
		return known;
	}

	/** The id of the block that links `row`, or -1; the blocks of every row are found the first time one is asked for. */
	function homeOf(row:Int):Int {
		if (!rowsFound) {
			IrPassScratch.filledInts(rowBlocks, body.rowLimit(), -1);
			for (block in 0...body.blockCount()) {
				var id = body.blockId(block), at = body.firstRow(block);
				while (at >= 0) {
					rowBlocks[at] = id;
					at = body.nextRow(at);
				}
			}
			rowsFound = true;
		}
		return row >= 0 ? rowBlocks[row] : -1;
	}

	/** Whether `row` is one of the phis block `id` starts with. */
	function leadingPhiOf(row:Int, id:Int):Bool {
		var at = body.firstRow(graph.indexOf(id));
		while (at >= 0 && body.opcode(at) == IrOpcode.Phi) {
			if (at == row)
				return true;
			at = body.nextRow(at);
		}
		return false;
	}

	/** Whitelist by ABI binding, not by source function name. These implementations accept only scalar arguments. */
	public static function pureNativeCalls(natives:Array<IrNative>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (native in natives)
			if (native.library == "haxeon_runtime")
				switch native.symbol {
					case "__math_sqrt", "__math_abs", "__math_floor", "__math_ceil", "__math_min", "__math_max",
						"__math_is_finite", "__math_is_nan":
						var scalar = isScalar(native.result);
						for (argument in native.arguments)
							if (!isScalar(argument))
								scalar = false;
						if (scalar)
							result.set(native.name, true);
					default:
				}
		return result;
	}

	static function isScalar(type:IrType):Bool
		return switch type {
			case F64, I32, Bool: true;
			default: false;
		};

	/** How many loops hold block `id`. */
	public function depth(id:Int):Int
		return forest().depthOf(id);

	public function dominates(a:Int, b:Int):Bool
		return graph.dominates(a, b);

	/**
	 * Whether a loop around block `id` defines none of `inputs` but constants, so an operation of them could be computed
	 * before it.
	 */
	public function invariantInputs(inputs:Array<IrValueId>, id:Int):Bool {
		var loops = forest(), loop = loops.loopOf(id);
		while (loop >= 0) {
			var invariant = true;
			for (input in inputs) {
				var definition = body.definingRow(input);
				if (definition >= 0 && loops.contains(loop, homeOf(definition)))
					switch body.opcode(definition) {
						case IrOpcode.ConstInt, IrOpcode.ConstFloat, IrOpcode.ConstBool:
						default:
							invariant = false;
					}
			}
			if (invariant)
				return true;
			loop = loops.parent(loop);
		}
		return false;
	}

	/** Whether `index` is in range of `array` at an access in block `accessBlock`, by a loop around it. */
	public function proven(array:IrValueId, index:IrValueId, accessBlock:Int):Bool {
		// A handler's entry from inside the loop carries none of its facts. Only a loop's counter can be proved, a phi of its
		// header or that plus something, so an access with another index does not need the loops.
		if (graph.hasTry || !countsInHeader(index))
			return false;
		var loops = forest(), loop = loops.loopOf(accessBlock);
		while (loop >= 0) {
			if (stable(loop) && inductionStart(index, loop)) {
				var value = startValue, offset = startOffset;
				stamp++;
				if (startsNonnegative(value, offset, loops.header(loop)) && guarded(array, index, accessBlock, loop))
					return true;
			}
			loop = loops.parent(loop);
		}
		return false;
	}

	/**
	 * Whether `index` is a phi, or a phi plus something, of a block a back edge enters: what every index `inductionStart` reads
	 * is. A phi's block is the successor of its first input's block that it leads.
	 */
	function countsInHeader(index:IrValueId):Bool {
		var row = body.definingRow(index);
		if (row >= 0 && body.opcode(row) == IrOpcode.Add)
			row = body.definingRow(body.operand(row, 0));
		if (row < 0 || body.opcode(row) != IrOpcode.Phi || body.operandCount(row) == 0)
			return false;
		var from = body.auxInt(row, 0);
		if (!graph.isReachable(from))
			return false;
		for (successor in 0...graph.successorCount(from)) {
			var header = graph.successor(from, successor);
			if (leadingPhiOf(row, header)) {
				for (edge in 0...graph.predecessorCount(header))
					if (graph.dominates(header, graph.predecessor(header, edge)))
						return true;
				return false;
			}
		}
		return false;
	}

	function guarded(array:IrValueId, index:IrValueId, accessBlock:Int, loop:Int):Bool {
		for (id in graph.order)
			if (loops.contains(loop, id)) {
				var row = body.terminatorRow(graph.indexOf(id));
				if (row < 0 || body.opcode(row) != IrOpcode.Branch)
					continue;
				var yes = body.successor(row, 0), no = body.successor(row, 1);
				if (!loops.contains(loop, yes) || loops.contains(loop, no) || !graph.dominates(yes, accessBlock))
					continue;
				var condition = body.definingRow(body.operand(row, 0));
				if (condition < 0 || body.opcode(condition) != IrOpcode.Less || body.operand(condition, 0) != index)
					continue;
				var length = body.operand(condition, 1), size = body.definingRow(length);
				if (size >= 0 && body.opcode(size) == IrOpcode.ArraySize && body.operand(size, 0) == array)
					return unchangedSince(length, id);
			}
		return false;
	}

	/** Whether the first index the loop tests, `value + offset`, is at least zero. */
	function startsNonnegative(value:IrValueId, offset:Int, header:Int):Bool {
		if (offset == 0)
			return nonnegative(value, header);
		var literal = integer(value, 0);
		return literal != null && literal + offset >= 0;
	}

	/**
	 * Where `index` starts in `loop` (`startValue` and `startOffset`), when it is an induction variable counting up by one from
	 * a value before the loop, or that value plus one, tested before its first use (`index = i + 1` with `i` starting at
	 * `start - 1`, or at a constant, as a for-in over an array counts from -1).
	 */
	function inductionStart(index:IrValueId, loop:Int):Bool {
		var phi = index, preincrement = false, row = body.definingRow(index);
		if (row >= 0 && body.opcode(row) == IrOpcode.Add && one(body.operand(row, 1))) {
			phi = body.operand(row, 0);
			preincrement = true;
		}
		row = body.definingRow(phi);
		if (row < 0 || body.opcode(row) != IrOpcode.Phi || !isInt(phi) || !leadingPhiOf(row, loops.header(loop)))
			return false;
		var start = IrValueId.of(-1), offset = 0, step = false;
		for (input in 0...body.operandCount(row)) {
			var value = body.operand(row, input);
			if (!loops.contains(loop, body.auxInt(row, input))) {
				var initial = value, initialOffset = 0;
				if (preincrement) {
					var definition = body.definingRow(initial);
					switch definition < 0 ? IrOpcode.Phi : body.opcode(definition) {
						case IrOpcode.Sub if (one(body.operand(definition, 1))):
							initial = body.operand(definition, 0);
						case IrOpcode.ConstInt:
							initialOffset = 1;
						default:
							return false;
					}
				}
				if (start.exists() && (start != initial || offset != initialOffset))
					return false;
				start = initial;
				offset = initialOffset;
			} else if (preincrement) {
				if (value != index)
					return false;
				step = true;
			} else {
				var definition = body.definingRow(value);
				if (definition < 0 || body.opcode(definition) != IrOpcode.Add || body.operand(definition, 0) != index
					|| !one(body.operand(definition, 1)))
					return false;
				step = true;
			}
		}
		if (!step || !start.exists())
			return false;
		startValue = start;
		startOffset = offset;
		return true;
	}

	function one(value:IrValueId):Bool {
		var n = integer(value, 0);
		return n != null && n == 1;
	}

	/** The constant `value` is, adding and subtracting constants; `depth` bounds the walk. */
	function integer(value:IrValueId, depth:Int):Null<Int> {
		var row = body.definingRow(value);
		if (row < 0 || depth > 32)
			return null;
		return switch body.opcode(row) {
			case IrOpcode.ConstInt: body.aux(row);
			case IrOpcode.Add, IrOpcode.Sub:
				var a = integer(body.operand(row, 0), depth + 1), b = integer(body.operand(row, 1), depth + 1);
				if (a == null || b == null) null;
				else body.opcode(row) == IrOpcode.Add ? a + b : a - b;
			default: null;
		};
	}

	function nonnegative(value:IrValueId, atBlock:Int):Bool {
		var literal = integer(value, 0);
		if (literal != null)
			return literal >= 0;
		var id:Int = value;
		while (seenValues.length <= id)
			seenValues.push(0);
		if (seenValues[id] == stamp)
			return false;
		seenValues[id] = stamp;
		// Nested i+1 is safe: its enclosing length guard proves i <= Int.MAX_VALUE-1.
		var row = body.definingRow(value);
		if (row >= 0 && body.opcode(row) == IrOpcode.Add && one(body.operand(row, 1)))
			return boundedIndex(body.operand(row, 0), atBlock);
		return boundedIndex(value, atBlock);
	}

	function boundedIndex(value:IrValueId, atBlock:Int):Bool {
		var loop = loops.loopOf(atBlock);
		while (loop >= 0) {
			if (stable(loop) && inductionStart(value, loop)
				&& startsNonnegative(startValue, startOffset, loops.header(loop))
				&& testedAgainstLength(value, atBlock, loop))
				return true;
			loop = loops.parent(loop);
		}
		return false;
	}

	/** Whether a branch of `loop` that stays in it only while `value` is below some array's length dominates `atBlock`. */
	function testedAgainstLength(value:IrValueId, atBlock:Int, loop:Int):Bool {
		for (id in graph.order)
			if (loops.contains(loop, id)) {
				var row = body.terminatorRow(graph.indexOf(id));
				if (row < 0 || body.opcode(row) != IrOpcode.Branch)
					continue;
				var yes = body.successor(row, 0), no = body.successor(row, 1);
				if (!loops.contains(loop, yes) || loops.contains(loop, no) || !graph.dominates(yes, atBlock))
					continue;
				var condition = body.definingRow(body.operand(row, 0));
				if (condition < 0 || body.opcode(condition) != IrOpcode.Less || body.operand(condition, 0) != value)
					continue;
				var size = body.definingRow(body.operand(condition, 1));
				if (size >= 0 && body.opcode(size) == IrOpcode.ArraySize)
					return true;
			}
		return false;
	}

	function stable(loop:Int):Bool {
		if (stableLoops[loop] == 0)
			stableLoops[loop] = resizesNothing(loop) ? 1 : 2;
		return stableLoops[loop] == 1;
	}

	function resizesNothing(loop:Int):Bool {
		for (id in graph.order)
			if (loops.contains(loop, id)) {
				var row = body.firstRow(graph.indexOf(id));
				while (row >= 0) {
					if (mayResize(row))
						return false;
					row = body.nextRow(row);
				}
			}
		return true;
	}

	/** A captured length must also survive code between its definition and loop entry. */
	function unchangedSince(length:IrValueId, guardBlock:Int):Bool {
		var definition = body.definingRow(length), home = homeOf(definition);
		if (home < 0 || !graph.dominates(home, guardBlock))
			return false;
		stamp++;
		pending.resize(0);
		pending.push(guardBlock);
		while (pending.length > 0) {
			var id = pending.pop();
			while (seenBlocks.length <= id)
				seenBlocks.push(0);
			if (seenBlocks[id] == stamp)
				continue;
			seenBlocks[id] = stamp;
			var after = id != home, row = body.firstRow(graph.indexOf(id));
			while (row >= 0) {
				if (after && mayResize(row))
					return false;
				if (row == definition)
					after = true;
				row = body.nextRow(row);
			}
			if (id != home)
				for (index in 0...graph.predecessorCount(id))
					pending.push(graph.predecessor(id, index));
		}
		return true;
	}

	/**
	 * Calls that leave every array's size as it is: the runtime's value array reads and checks, and the conversions of a
	 * scalar to and from its storage word (`IrScalarWordBits`).
	 */
	static function readsValueArray(name:String):Bool
		return StringTools.startsWith(name, "__value_array_read_") || name == "__value_array_validate"
			|| name == "__value_array_is_initialized" || IrScalarWordBits.matches(name);

	function mayResize(row:Int):Bool
		return switch body.opcode(row) {
			case IrOpcode.Call:
				var name = body.symbol(row).name;
				!(name == IrReceiverCheck.NAME || name == IrReferenceIdentity.NAME || pureCalls.exists(name)
					|| readsValueArray(name));
			case IrOpcode.CNativeCall, IrOpcode.CallClosure, IrOpcode.MethodCall, IrOpcode.MemoryStore,
				IrOpcode.ArraySet,
				IrOpcode.IteratorNew, IrOpcode.IteratorNext, IrOpcode.IteratorHasNext, IrOpcode.SafeCast,
				IrOpcode.ToVirtual:
				true;
			case IrOpcode.FieldSet:
				switch body.valueType(body.operand(row, 0)) {
					case Obj(_): false;
					default: true;
				}
			default: false;
		};

	function isInt(value:IrValueId):Bool
		return switch body.valueType(value) {
			case I32: true;
			default: false;
		};
}
