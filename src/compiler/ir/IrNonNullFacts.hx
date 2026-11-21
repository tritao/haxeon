package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrPassScratch.IrNonNullScratch;
import compiler.ir.IrPassScratch.IrValueMarks;

/** Must facts at instruction entry; SSA values are never invalidated by a call or a store. */
class IrNonNullFacts {
	/**
	 * The rows of the scratch the analysis ran in: per block id, where its run of words starts in `provenWords` (-1 for a block
	 * with no proven receiver) and how long it is, a bit per instruction index whose receiver is proven non-null. Null when
	 * nothing was analyzed.
	 */
	final rows:Null<IrNonNullScratch> = null;

	/** Whether any instruction of `fn` has a receiver whose non-nullness could be proven: without one there is nothing to analyze. */
	static function hasReceiver(fn:IrFunction):Bool {
		for (block in fn.blocks)
			for (located in block.instructions)
				if (checked(located.value) != null)
					return true;
		return false;
	}

	/**
	 * `graph`, when given, is `fn`'s, shared with other analyses of the same unchanged function; `scratch`, the caller's
	 * tables reused across functions (`IrPassScratch.nonNull`). The facts are kept in `scratch`: they hold until it is next
	 * given to an analysis.
	 */
	public function new(fn:IrFunction, ?checkedDereferences:Bool = false, ?graph:IrGraph, ?scratch:IrNonNullScratch) {
		if (hasReceiver(fn)) {
			var tables = scratch ?? new IrNonNullScratch();
			new NonNullFlow(fn, checkedDereferences, graph, tables).run();
			rows = tables;
		}
	}

	public function has(block:Int, index:Int):Bool {
		var rows = this.rows;
		if (rows == null || block < 0 || block >= rows.provenStart.length)
			return false;
		var start = rows.provenStart[block], word = index >>> 5;
		return start >= 0 && word < rows.provenLength[block]
			&& (rows.provenWords[start + word] & (1 << (index & 31))) != 0;
	}

	/**
	 * The analysis on a body: the rows whose receiver is proven non-null on entry, marked in `scratch.provenRows` (cleared first),
	 * which holds them until it is next given to an analysis. `graph` is the body's.
	 */
	public static function analyzeBody(body:IrBody, checkedDereferences:Bool, graph:IrBodyGraph,
			scratch:IrNonNullScratch):IrValueMarks {
		scratch.provenRows.clear();
		var any = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0 && !any) {
				any = checkedRow(body, row).exists();
				row = body.nextRow(row);
			}
		}
		if (any)
			new NonNullBodyFlow(body, checkedDereferences, graph, scratch).run();
		return scratch.provenRows;
	}

	/** `checked` for a body's row: the receiver it dereferences, or a value that does not exist. */
	public static function checkedRow(body:IrBody, row:Int):IrValueId
		return switch body.opcode(row) {
			case IrOpcode.Call:
				body.symbol(row).name == IrReceiverCheck.NAME && body.operandCount(row) == 1 ? body.operand(row,
					0) : IrValueId.of(-1);
			case IrOpcode.FieldGet, IrOpcode.FieldSet, IrOpcode.MethodCall, IrOpcode.InstanceClosure, IrOpcode.ArrayGet,
				IrOpcode.ArraySet, IrOpcode.ArraySize, IrOpcode.IteratorNew, IrOpcode.IteratorHasNext,
				IrOpcode.IteratorNext,
				IrOpcode.EnumIndex, IrOpcode.EnumField: body.operand(row, 0);
			default: IrValueId.of(-1);
		};

	public static function checked(instruction:IrInstruction):Null<IrValue>
		return switch instruction {
			case Call(_, name, arguments) if (name.name == IrReceiverCheck.NAME && arguments.length == 1): arguments[0];
			case FieldGet(_, v, _), FieldSet(v, _, _), MethodCall(_, v, _, _, _), InstanceClosure(_, _, v),
				ArrayGet(_, v, _), ArraySet(v, _, _),
				ArraySize(_, v), IteratorNew(_, v), IteratorHasNext(_, v), IteratorNext(_, v), EnumIndex(_, v),
				EnumField(_, v, _, _): v;
			default: null;
		}
}

/**
 * The analysis of one function. Values and blocks are small ids within a function, so every table is an array indexed by
 * id, and a set of facts is a row of words: one bit per value that has a fact.
 */
private class NonNullFlow {
	final fn:IrFunction;
	final checkedDereferences:Bool;
	final graph:IrGraph;
	final scratch:IrNonNullScratch;

	/** Per value id, its fact bit, or -1 for a value that cannot have one. */
	final positions:Array<Int>;

	/** Per value id of a Bool, the value one of its branch's edges proves non-null, or -1; and which edge. */
	final testValue:Array<Int>;

	final testOnTrue:Array<Bool>;
	var words = 0;

	/** Per block id, the facts leaving it: a row of `words` words. Kept only without exception edges, for reachable blocks. */
	final outgoing:Array<Int>;

	var hasRows = false;

	public function new(fn:IrFunction, checkedDereferences:Bool, graph:Null<IrGraph>, scratch:IrNonNullScratch) {
		this.fn = fn;
		this.checkedDereferences = checkedDereferences;
		this.graph = graph ?? new IrGraph(fn);
		this.scratch = scratch;
		positions = scratch.positions;
		testValue = scratch.testValue;
		testOnTrue = scratch.testOnTrue;
		outgoing = scratch.outgoing;
	}

	public function run():Void {
		var valueCount = 0, blockCount = 0;
		for (argument in fn.arguments)
			if (argument.id >= valueCount)
				valueCount = argument.id + 1;
		for (block in fn.blocks) {
			if (block.id >= blockCount)
				blockCount = block.id + 1;
			for (located in block.instructions) {
				var out = IrOperands.output(located.value);
				if (out != null && out.id >= valueCount)
					valueCount = out.id + 1;
			}
		}
		// A fact can affect a receiver through an upcast or phi even if it is not itself a receiver.
		filledInts(positions, valueCount, -1);
		var count = 0;
		for (argument in fn.arguments)
			if (positions[argument.id] < 0)
				positions[argument.id] = count++;
		var nulls = filledBools(scratch.nulls, valueCount, false), fresh = scratch.fresh, hasTry = false;
		fresh.resize(0);
		for (block in fn.blocks)
			for (located in block.instructions) {
				var out = IrOperands.output(located.value);
				if (out != null && positions[out.id] < 0)
					positions[out.id] = count++;
				switch located.value {
					case ConstNull(out):
						nulls[out.id] = true;
					case NewObject(out, _), ValueInit(out), StaticClosure(out, _), InstanceClosure(out, _, _):
						fresh.push(out.id);
					case BeginTry(_, _, _), EndTry(_, _), Catch(_):
						hasTry = true;
					default:
				}
			}
		filledInts(testValue, valueCount, -1);
		filledBools(testOnTrue, valueCount, false);
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					// An exact-class test holds only for a non-null object (IrExactTypeFacts).
					case Call(out, name, arguments) if (name.name == IrExactTypeFacts.TEST && arguments.length == 2):
						testValue[out.id] = arguments[0].id;
						testOnTrue[out.id] = true;
					case Equal(out, left, right):
						if (isNull(nulls, left.id))
							testValue[out.id] = right.id;
						else if (isNull(nulls, right.id))
							testValue[out.id] = left.id;
					default:
				}
		words = (count + 31) >>> 5;
		var before = filledInts(scratch.before, words, 0), after = filledInts(scratch.after, words, 0);
		// Without exception edges the facts flow to a fixed point; each reachable block keeps the row it enters with and the
		// row it leaves with, starting from "everything" so the intersection over predecessors only ever shrinks.
		var incoming = scratch.incoming;
		if (!hasTry) {
			hasRows = true;
			filledInts(incoming, blockCount * words, 0);
			filledInts(outgoing, blockCount * words, 0);
			for (id in graph.order)
				for (word in 0...words)
					outgoing[id * words + word] = word == words - 1
						&& (count & 31) != 0 ? -1 >>> (32 - (count & 31)) : -1;
			var entry = fn.blocks[0].id, changed = true;
			while (changed) {
				changed = false;
				for (id in graph.order) {
					var count = graph.predecessorCount(id);
					if (id != entry && count > 0) {
						var first = graph.predecessor(id, 0);
						loadEdge(before, first, edgeFact(first, id));
						for (i in 1...count) {
							var pred = graph.predecessor(id, i);
							intersectEdge(before, pred, edgeFact(pred, id));
						}
					} else
						clear(before);
					for (word in 0...words) {
						incoming[id * words + word] = before[word];
						after[word] = before[word];
					}
					for (located in graph.block(id).instructions)
						transfer(located.value, after, id, true);
					var base = id * words;
					for (word in 0...words)
						if (outgoing[base + word] != after[word]) {
							outgoing[base + word] = after[word];
							changed = true;
						}
				}
			}
		}
		var facts = before,
			provenStart = filledInts(scratch.provenStart, blockCount, -1),
			provenLength = filledInts(scratch.provenLength, blockCount, 0),
			provenWords = scratch.provenWords;
		provenWords.resize(0);
		for (block in fn.blocks) {
			var start = -1;
			if (hasRows && graph.isReachable(block.id))
				for (word in 0...words)
					facts[word] = incoming[block.id * words + word];
				else
					clear(facts);
			// Fresh SSA definitions stay non-null even when exception edges prevent propagating check facts.
			if (hasTry)
				for (value in fresh)
					set(facts, value, true);
			for (index in 0...block.instructions.length) {
				var located = block.instructions[index],
					receiver = IrNonNullFacts.checked(located.value);
				if (receiver != null && has(facts, receiver.id)) {
					if (start < 0) {
						var length = ((block.instructions.length - 1) >>> 5) + 1;
						start = provenWords.length;
						for (_ in 0...length)
							provenWords.push(0);
						provenStart[block.id] = start;
						provenLength[block.id] = length;
					}
					provenWords[start + (index >>> 5)] |= 1 << (index & 31);
				}
				transfer(located.value, facts, block.id, !hasTry);
			}
		}
	}

	static function isNull(nulls:Array<Bool>, value:Int):Bool
		return value >= 0 && value < nulls.length && nulls[value];

	function position(value:Int):Int
		return value >= 0 && value < positions.length ? positions[value] : -1;

	function has(facts:Array<Int>, value:Int):Bool {
		var index = position(value);
		return index >= 0 && (facts[index >>> 5] & (1 << (index & 31))) != 0;
	}

	function set(facts:Array<Int>, value:Int, present:Bool):Void {
		var index = position(value);
		if (index < 0)
			return;
		if (present)
			facts[index >>> 5] |= 1 << (index & 31);
		else
			facts[index >>> 5] &= ~(1 << (index & 31));
	}

	function clear(facts:Array<Int>):Void
		for (word in 0...words)
			facts[word] = 0;

	/** Whether `block` has a row of outgoing facts; one without leaves nothing, as far as its successors know. */
	function hasRow(block:Int):Bool
		return hasRows && graph.isReachable(block);

	/** `facts` becomes the facts along the edge from `from`: its outgoing facts plus `fact` (-1 for none). */
	function loadEdge(facts:Array<Int>, from:Int, fact:Int):Void {
		if (hasRow(from))
			for (word in 0...words)
				facts[word] = outgoing[from * words + word];
			else
				clear(facts);
		if (fact >= 0)
			set(facts, fact, true);
	}

	/** Intersects `facts` with the facts along another edge into the same block, as `loadEdge` describes them. */
	function intersectEdge(facts:Array<Int>, from:Int, fact:Int):Void {
		var factIndex = fact >= 0 ? position(fact) : -1,
			factWord = factIndex < 0 ? -1 : factIndex >>> 5,
			factBit = factIndex < 0 ? 0 : 1 << (factIndex & 31),
			row = hasRow(from);
		for (word in 0...words) {
			var along = row ? outgoing[from * words + word] : 0;
			if (word == factWord)
				along |= factBit;
			facts[word] &= along;
		}
	}

	function transfer(instruction:IrInstruction, facts:Array<Int>, block:Int, allowPhi:Bool):Void {
		var receiver = IrNonNullFacts.checked(instruction);
		if (receiver != null && (checkedDereferences || isExplicitCheck(instruction)))
			set(facts, receiver.id, true);
		switch instruction {
			case NewObject(out, _), ValueInit(out), StaticClosure(out, _), InstanceClosure(out, _, _):
				set(facts, out.id, true);
			// A cast of a non-null value is non-null: it returns the value or throws.
			case Upcast(out, value), SafeCast(out, value):
				if (has(facts, value.id))
					set(facts, out.id, true);
			case Phi(out, inputs) if (allowPhi && inputs.length > 0):
				var all = true;
				for (input in inputs) {
					if (!edgeHas(input.block, block, input.value.id)) {
						all = false;
						break;
					}
				}
				set(facts, out.id, all);
			default:
		}
	}

	static function isExplicitCheck(instruction:IrInstruction):Bool
		return switch instruction {
			case Call(_, name, arguments) if (name.name == IrReceiverCheck.NAME && arguments.length == 1): true;
			case MethodCall(_, _, _, _, _): true;
			default: false;
		}

	/** The value the edge from `from` to `to` proves non-null (a null test failed, or an exact-class test held), or -1. */
	function edgeFact(from:Int, to:Int):Int {
		if (!graph.contains(from))
			return -1;
		var term = graph.block(from).terminator;
		if (term != null)
			switch term.value {
				case Branch(condition, yes, no) if (yes != no && testOf(condition.id) >= 0):
					if ((testOnTrue[condition.id] ? yes : no) == to)
						return testValue[condition.id];
				default:
			}
		return -1;
	}

	function edgeHas(from:Int, to:Int, value:Int):Bool {
		if (hasRow(from)) {
			var index = position(value);
			if (index >= 0 && (outgoing[from * words + (index >>> 5)] & (1 << (index & 31))) != 0)
				return true;
		}
		return edgeFact(from, to) == value && value >= 0;
	}

	function testOf(condition:Int):Int
		return condition >= 0 && condition < testValue.length ? testValue[condition] : -1;

	static inline function filledInts(values:Array<Int>, count:Int, value:Int):Array<Int>
		return IrPassScratch.filledInts(values, count, value);

	static inline function filledBools(values:Array<Bool>, count:Int, value:Bool):Array<Bool>
		return IrPassScratch.filledBools(values, count, value);
}

/** `NonNullFlow` on a body: the same facts, proven per row instead of per instruction index. */
private class NonNullBodyFlow {
	final body:IrBody;
	final checkedDereferences:Bool;
	final graph:IrBodyGraph;
	final scratch:IrNonNullScratch;
	final positions:Array<Int>;
	final testValue:Array<Int>;
	final testOnTrue:Array<Bool>;
	final outgoing:Array<Int>;
	final receiverCheck:Int;
	var words = 0;
	var hasRows = false;

	public function new(body:IrBody, checkedDereferences:Bool, graph:IrBodyGraph, scratch:IrNonNullScratch) {
		this.body = body;
		this.checkedDereferences = checkedDereferences;
		this.graph = graph;
		this.scratch = scratch;
		positions = scratch.positions;
		testValue = scratch.testValue;
		testOnTrue = scratch.testOnTrue;
		outgoing = scratch.outgoing;
		receiverCheck = IrSymbol.of(IrReceiverCheck.NAME).id;
	}

	public function run():Void {
		var valueCount = body.valueLimit(), blockCount = 0;
		for (block in 0...body.blockCount())
			if (body.blockId(block) >= blockCount)
				blockCount = body.blockId(block) + 1;
		filledInts(positions, valueCount, -1);
		var count = 0;
		for (index in 0...body.argumentCount())
			if (positions[body.argument(index)] < 0)
				positions[body.argument(index)] = count++;
		var nulls = filledBools(scratch.nulls, valueCount, false),
			fresh = scratch.fresh,
			hasTry = false,
			exactTest = IrSymbol.of(IrExactTypeFacts.TEST).id;
		fresh.resize(0);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), terminator = body.terminatorRow(block);
			while (row >= 0 && row != terminator) {
				var out = body.output(row);
				if (out.exists() && positions[out] < 0)
					positions[out] = count++;
				switch body.opcode(row) {
					case IrOpcode.ConstNull:
						nulls[out] = true;
					case IrOpcode.NewObject, IrOpcode.ValueInit, IrOpcode.StaticClosure, IrOpcode.InstanceClosure:
						fresh.push(out);
					case IrOpcode.BeginTry, IrOpcode.EndTry, IrOpcode.Catch:
						hasTry = true;
					default:
				}
				row = body.nextRow(row);
			}
		}
		filledInts(testValue, valueCount, -1);
		filledBools(testOnTrue, valueCount, false);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					// An exact-class test holds only for a non-null object (IrExactTypeFacts).
					case IrOpcode.Call if (body.aux(row) == exactTest && body.operandCount(row) == 2):
						testValue[body.output(row)] = body.operand(row, 0);
						testOnTrue[body.output(row)] = true;
					case IrOpcode.Equal:
						var left = body.operand(row, 0), right = body.operand(row, 1);
						if (isNull(nulls, left))
							testValue[body.output(row)] = right;
						else if (isNull(nulls, right))
							testValue[body.output(row)] = left;
					default:
				}
				row = body.nextRow(row);
			}
		}
		words = (count + 31) >>> 5;
		var before = filledInts(scratch.before, words, 0), after = filledInts(scratch.after, words, 0);
		var incoming = scratch.incoming;
		if (!hasTry) {
			hasRows = true;
			filledInts(incoming, blockCount * words, 0);
			filledInts(outgoing, blockCount * words, 0);
			for (id in graph.order)
				for (word in 0...words)
					outgoing[id * words + word] = word == words - 1
						&& (count & 31) != 0 ? -1 >>> (32 - (count & 31)) : -1;
			var entry = body.blockId(0), changed = true;
			while (changed) {
				changed = false;
				for (id in graph.order) {
					var predecessors = graph.predecessorCount(id);
					if (id != entry && predecessors > 0) {
						var first = graph.predecessor(id, 0);
						loadEdge(before, first, edgeFact(first, id));
						for (i in 1...predecessors) {
							var pred = graph.predecessor(id, i);
							intersectEdge(before, pred, edgeFact(pred, id));
						}
					} else
						clear(before);
					for (word in 0...words) {
						incoming[id * words + word] = before[word];
						after[word] = before[word];
					}
					var block = graph.indexOf(id), row = body.firstRow(block), terminator = body.terminatorRow(block);
					while (row >= 0 && row != terminator) {
						transfer(row, after, id, true);
						row = body.nextRow(row);
					}
					var base = id * words;
					for (word in 0...words)
						if (outgoing[base + word] != after[word]) {
							outgoing[base + word] = after[word];
							changed = true;
						}
				}
			}
		}
		var facts = before, proven = scratch.provenRows;
		for (block in 0...body.blockCount()) {
			var id = body.blockId(block);
			if (hasRows && graph.isReachable(id))
				for (word in 0...words)
					facts[word] = incoming[id * words + word];
				else
					clear(facts);
			// Fresh SSA definitions stay non-null even when exception edges prevent propagating check facts.
			if (hasTry)
				for (value in fresh)
					set(facts, value, true);
			var row = body.firstRow(block), terminator = body.terminatorRow(block);
			while (row >= 0 && row != terminator) {
				var receiver = IrNonNullFacts.checkedRow(body, row);
				if (receiver.exists() && has(facts, receiver))
					proven.add(row);
				transfer(row, facts, id, !hasTry);
				row = body.nextRow(row);
			}
		}
	}

	static function isNull(nulls:Array<Bool>, value:Int):Bool
		return value >= 0 && value < nulls.length && nulls[value];

	function position(value:Int):Int
		return value >= 0 && value < positions.length ? positions[value] : -1;

	function has(facts:Array<Int>, value:Int):Bool {
		var index = position(value);
		return index >= 0 && (facts[index >>> 5] & (1 << (index & 31))) != 0;
	}

	function set(facts:Array<Int>, value:Int, present:Bool):Void {
		var index = position(value);
		if (index < 0)
			return;
		if (present)
			facts[index >>> 5] |= 1 << (index & 31);
		else
			facts[index >>> 5] &= ~(1 << (index & 31));
	}

	function clear(facts:Array<Int>):Void
		for (word in 0...words)
			facts[word] = 0;

	function hasRow(block:Int):Bool
		return hasRows && graph.isReachable(block);

	function loadEdge(facts:Array<Int>, from:Int, fact:Int):Void {
		if (hasRow(from))
			for (word in 0...words)
				facts[word] = outgoing[from * words + word];
			else
				clear(facts);
		if (fact >= 0)
			set(facts, fact, true);
	}

	function intersectEdge(facts:Array<Int>, from:Int, fact:Int):Void {
		var factIndex = fact >= 0 ? position(fact) : -1,
			factWord = factIndex < 0 ? -1 : factIndex >>> 5,
			factBit = factIndex < 0 ? 0 : 1 << (factIndex & 31),
			row = hasRow(from);
		for (word in 0...words) {
			var along = row ? outgoing[from * words + word] : 0;
			if (word == factWord)
				along |= factBit;
			facts[word] &= along;
		}
	}

	function transfer(row:Int, facts:Array<Int>, block:Int, allowPhi:Bool):Void {
		var receiver = IrNonNullFacts.checkedRow(body, row), opcode = body.opcode(row);
		if (receiver.exists() && (checkedDereferences || opcode == IrOpcode.MethodCall
			|| opcode == IrOpcode.Call && body.aux(row) == receiverCheck))
			set(facts, receiver, true);
		switch opcode {
			case IrOpcode.NewObject, IrOpcode.ValueInit, IrOpcode.StaticClosure, IrOpcode.InstanceClosure:
				set(facts, body.output(row), true);
			// A cast of a non-null value is non-null: it returns the value or throws.
			case IrOpcode.Upcast, IrOpcode.SafeCast:
				if (has(facts, body.operand(row, 0)))
					set(facts, body.output(row), true);
			case IrOpcode.Phi if (allowPhi && body.operandCount(row) > 0):
				var all = true;
				for (input in 0...body.operandCount(row))
					if (!edgeHas(body.auxInt(row, input), block, body.operand(row, input))) {
						all = false;
						break;
					}
				set(facts, body.output(row), all);
			default:
		}
	}

	function edgeFact(from:Int, to:Int):Int {
		if (!graph.contains(from))
			return -1;
		var term = body.terminatorRow(graph.indexOf(from));
		if (term >= 0 && body.opcode(term) == IrOpcode.Branch) {
			var condition = body.operand(term, 0), yes = body.auxInt(term, 0), no = body.auxInt(term, 1);
			if (yes != no && testOf(condition) >= 0 && (testOnTrue[condition] ? yes : no) == to)
				return testValue[condition];
		}
		return -1;
	}

	function edgeHas(from:Int, to:Int, value:Int):Bool {
		if (hasRow(from)) {
			var index = position(value);
			if (index >= 0 && (outgoing[from * words + (index >>> 5)] & (1 << (index & 31))) != 0)
				return true;
		}
		return edgeFact(from, to) == value && value >= 0;
	}

	function testOf(condition:Int):Int
		return condition >= 0 && condition < testValue.length ? testValue[condition] : -1;

	static inline function filledInts(values:Array<Int>, count:Int, value:Int):Array<Int>
		return IrPassScratch.filledInts(values, count, value);

	static inline function filledBools(values:Array<Bool>, count:Int, value:Bool):Array<Bool>
		return IrPassScratch.filledBools(values, count, value);
}
