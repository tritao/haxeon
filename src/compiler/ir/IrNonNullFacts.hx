package compiler.ir;

import compiler.ir.Ir;

/** Must facts at instruction entry; SSA values are never invalidated by a call or a store. */
class IrNonNullFacts {
	/** Per block id, a bit per instruction index whose receiver is proven non-null; null for a block with none. */
	final proven:Array<Null<Array<Int>>> = [];

	/** Whether any instruction of `fn` has a receiver whose non-nullness could be proven: without one there is nothing to analyze. */
	static function hasReceiver(fn:IrFunction):Bool {
		for (block in fn.blocks)
			for (located in block.instructions)
				if (checked(located.value) != null)
					return true;
		return false;
	}

	public function new(fn:IrFunction, ?checkedDereferences:Bool = false) {
		if (hasReceiver(fn))
			new NonNullFlow(fn, checkedDereferences, proven).run();
	}

	public function has(block:Int, index:Int):Bool {
		var at = block >= 0 && block < proven.length ? proven[block] : null, word = index >>> 5;
		return at != null && word < at.length && (at[word] & (1 << (index & 31))) != 0;
	}

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
	final proven:Array<Null<Array<Int>>>;
	final graph:IrGraph;

	/** Per value id, its fact bit, or -1 for a value that cannot have one. */
	var positions:Array<Int> = [];

	/** Per value id of a Bool, the value one of its branch's edges proves non-null, or -1; and which edge. */
	var testValue:Array<Int> = [];

	var testOnTrue:Array<Bool> = [];
	var words = 0;

	/** Per block id, the facts leaving it: a row of `words` words. Kept only without exception edges, for reachable blocks. */
	var outgoing:Array<Int> = [];

	var hasRows = false;

	public function new(fn:IrFunction, checkedDereferences:Bool, proven:Array<Null<Array<Int>>>) {
		this.fn = fn;
		this.checkedDereferences = checkedDereferences;
		this.proven = proven;
		graph = new IrGraph(fn);
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
		positions = filledInts(valueCount, -1);
		var count = 0;
		for (argument in fn.arguments)
			if (positions[argument.id] < 0)
				positions[argument.id] = count++;
		var nulls = filledBools(valueCount, false), fresh:Array<Int> = [], hasTry = false;
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
		testValue = filledInts(valueCount, -1);
		testOnTrue = filledBools(valueCount, false);
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
		var before = filledInts(words, 0), after = filledInts(words, 0);
		// Without exception edges the facts flow to a fixed point; each reachable block keeps the row it enters with and the
		// row it leaves with, starting from "everything" so the intersection over predecessors only ever shrinks.
		var incoming:Array<Int> = [];
		if (!hasTry) {
			hasRows = true;
			incoming = filledInts(blockCount * words, 0);
			outgoing = filledInts(blockCount * words, 0);
			for (id in graph.order)
				for (word in 0...words)
					outgoing[id * words + word] = word == words - 1
						&& (count & 31) != 0 ? -1 >>> (32 - (count & 31)) : -1;
			var entry = fn.blocks[0].id, changed = true;
			while (changed) {
				changed = false;
				for (id in graph.order) {
					var preds = graph.predecessorsOf(id);
					if (id != entry && preds.length > 0) {
						loadEdge(before, preds[0], edgeFact(preds[0], id));
						for (i in 1...preds.length)
							intersectEdge(before, preds[i], edgeFact(preds[i], id));
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
		var facts = before;
		for (block in fn.blocks) {
			var at:Null<Array<Int>> = null;
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
					if (at == null)
						at = [];
					while (at.length <= index >>> 5)
						at.push(0);
					at[index >>> 5] |= 1 << (index & 31);
				}
				transfer(located.value, facts, block.id, !hasTry);
			}
			if (at != null) {
				while (proven.length <= block.id)
					proven.push(null);
				proven[block.id] = at;
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

	static function filledInts(count:Int, value:Int):Array<Int> {
		var values:Array<Int> = [];
		values.resize(count);
		for (index in 0...count)
			values[index] = value;
		return values;
	}

	static function filledBools(count:Int, value:Bool):Array<Bool> {
		var values:Array<Bool> = [];
		values.resize(count);
		for (index in 0...count)
			values[index] = value;
		return values;
	}
}
