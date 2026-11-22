package compiler.ir.analysis;

import compiler.ir.cfg.IrBodyGraph;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrValueId;
import compiler.ir.names.IrReceiverCheck;

import compiler.ir.model.Ir;
import compiler.ir.model.IrPassScratch.IrNonNullScratch;
import compiler.ir.model.IrPassScratch.IrValueMarks;

/** Must facts at instruction entry; SSA values are never invalidated by a call or a store. */
class IrNonNullFacts {
	/**
	 * The rows of the scratch the analysis ran in: per block id, where its run of words starts in `provenWords` (-1 for a block
	 * with no proven receiver) and how long it is, a bit per instruction index whose receiver is proven non-null.
	 */
	final rows:IrNonNullScratch;

	/**
	 * The facts of `fn`, by block id and instruction index, from the analysis of its body (`analyzeBody`); one that has none is
	 * encoded for it. `objectNamed` looks up the class its first argument names (`isMethodReceiver`); `fields` is as
	 * `analyzeBody` takes it.
	 */
	public function new(fn:IrFunction, checkedDereferences = false, ?objectNamed:String->Null<IrObject>,
			?fields:String->Map<String, Bool>) {
		var body = fn.body != null ? fn.body : IrBodyBuilder.encode(fn, IrTypeIds.ofFunctions([fn])),
			tables = new IrNonNullScratch(),
			receiverClass = receiverClass(body),
			receiver = receiverClass != null && objectNamed != null
				&& isMethodReceiver(body, objectNamed(receiverClass)),
			proven = analyzeBody(body, checkedDereferences, new IrBodyGraph().reset(body), tables, receiver, fields),
			blockCount = 0;
		for (block in 0...body.blockCount())
			if (body.blockId(block) >= blockCount)
				blockCount = body.blockId(block) + 1;
		var provenStart = IrPassScratch.filledInts(tables.provenStart, blockCount, -1),
			provenLength = IrPassScratch.filledInts(tables.provenLength, blockCount, 0),
			provenWords = tables.provenWords;
		provenWords.resize(0);
		for (block in 0...body.blockCount()) {
			var terminator = body.terminatorRow(block), count = 0, row = body.firstRow(block), start = -1;
			while (row >= 0 && row != terminator) {
				count++;
				row = body.nextRow(row);
			}
			row = body.firstRow(block);
			for (index in 0...count) {
				if (proven.has(row)) {
					if (start < 0) {
						var length = ((count - 1) >>> 5) + 1;
						start = provenWords.length;
						for (_ in 0...length)
							provenWords.push(0);
						provenStart[body.blockId(block)] = start;
						provenLength[body.blockId(block)] = length;
					}
					provenWords[start + (index >>> 5)] |= 1 << (index & 31);
				}
				row = body.nextRow(row);
			}
		}
		rows = tables;
	}

	public function has(block:Int, index:Int):Bool {
		var rows = this.rows;
		if (block < 0 || block >= rows.provenStart.length)
			return false;
		var start = rows.provenStart[block], word = index >>> 5;
		return start >= 0 && word < rows.provenLength[block]
			&& (rows.provenWords[start + word] & (1 << (index & 31))) != 0;
	}

	/**
	 * The analysis on a body: the rows whose receiver is proven non-null on entry, marked in `scratch.provenRows` (cleared first),
	 * which holds them until it is next given to an analysis. `graph` is the body's. With `receiver`, the first argument is
	 * non-null on entry (`isMethodReceiver`). `fields` gives the fields never null once constructed on a receiver of a class
	 * (`IrNonNullFields.fieldsOf`): a value read from one is non-null.
	 */
	public static function analyzeBody(body:IrBody, checkedDereferences:Bool, graph:IrBodyGraph,
			scratch:IrNonNullScratch,
			receiver = false, ?fields:String->Map<String, Bool>):IrValueMarks {
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
			new NonNullBodyFlow(body, checkedDereferences, graph, scratch, receiver, fields).run();
		return scratch.provenRows;
	}

	/**
	 * Whether `body`'s first argument is a receiver that is never null: `body` is a method or the constructor of `object`, a class,
	 * or a lambda and `object` its environment. Haxe checks the receiver of a method call at the call (a dereference, a receiver
	 * check, a dispatch that matched its class), so a method is never entered with a null `this`; nor is a constructor, which runs on
	 * the object just made or on its subclass's `this`; nor a lambda, whose closure binds the environment made for it. `object` is
	 * the object the first argument's type names, as the caller looks it up.
	 */
	public static function isMethodReceiver(body:IrBody, object:Null<IrObject>):Bool {
		if (object == null || object.isValue || body.argumentCount() == 0)
			return false;
		switch body.valueType(body.argument(0)) {
			case Obj(name) if (name == object.name):
			default:
				return false;
		}
		if (body.kind == SourceLambda)
			return StringTools.startsWith(object.name, compiler.semantic.LambdaName.ENVIRONMENT_PREFIX);
		if (body.name == object.name + ".new")
			return true;
		for (method in object.methods)
			if (method.functionName.name == body.name)
				return true;
		return false;
	}

	/** The class `body`'s first argument names, the one `isMethodReceiver` asks about; null for any other first argument. */
	public static function receiverClass(body:IrBody):Null<String>
		return body.argumentCount() == 0 ? null : switch body.valueType(body.argument(0)) {
			case Obj(name): name;
			default: null;
		};

	/** The receiver `row` dereferences or checks, or a value that does not exist. */
	public static function checkedRow(body:IrBody, row:Int):IrValueId
		return switch body.opcode(row) {
			case IrOpcode.Call:
				var name = body.symbol(row).name;
				(name == IrReceiverCheck.NAME || name == IrReceiverCheck.STRING_LENGTH)
					&& body.operandCount(row) == 1 ? body.operand(row, 0) : IrValueId.of(-1);
			case IrOpcode.FieldGet, IrOpcode.FieldSet, IrOpcode.MethodCall, IrOpcode.InstanceClosure, IrOpcode.ArrayGet,
				IrOpcode.ArraySet, IrOpcode.ArraySize, IrOpcode.IteratorNew, IrOpcode.IteratorHasNext,
				IrOpcode.IteratorNext,
				IrOpcode.EnumIndex, IrOpcode.EnumField: body.operand(row, 0);
			default: IrValueId.of(-1);
		};
}

/** The analysis of one body: per row, whether its receiver is proven non-null on entry. */
private class NonNullBodyFlow {
	final body:IrBody;
	final checkedDereferences:Bool;
	final graph:IrBodyGraph;
	final scratch:IrNonNullScratch;
	final positions:Array<Int>;
	final testValue:Array<Int>;
	final testOnTrue:Array<Bool>;
	final outgoing:Array<Int>;
	final receiver:Bool;
	final fields:Null<String->Map<String, Bool>>;

	/** Per value id, whether it is read from a field never null once constructed. */
	final fromFields:Array<Bool>;

	var words = 0;
	var hasRows = false;

	public function new(body:IrBody, checkedDereferences:Bool, graph:IrBodyGraph, scratch:IrNonNullScratch,
			receiver:Bool,
			fields:Null<String->Map<String, Bool>>) {
		this.receiver = receiver;
		this.fields = fields;
		fromFields = scratch.fromFields;
		this.body = body;
		this.checkedDereferences = checkedDereferences;
		this.graph = graph;
		this.scratch = scratch;
		positions = scratch.positions;
		testValue = scratch.testValue;
		testOnTrue = scratch.testOnTrue;
		outgoing = scratch.outgoing;
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
		if (receiver)
			fresh.push(body.argument(0));
		var lookup = fields;
		filledBools(fromFields, lookup == null ? 0 : valueCount, false);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), terminator = body.terminatorRow(block);
			while (row >= 0 && row != terminator) {
				var out = body.output(row);
				if (out.exists() && positions[out] < 0)
					positions[out] = count++;
				switch body.opcode(row) {
					case IrOpcode.ConstNull:
						nulls[out] = true;
					case IrOpcode.NewObject, IrOpcode.ValueInit, IrOpcode.StaticClosure, IrOpcode.InstanceClosure,
						IrOpcode.ConstString:
						fresh.push(out);
					case IrOpcode.FieldGet if (lookup != null):
						switch body.valueType(body.operand(row, 0)) {
							case Obj(type) if (lookup(type).exists(body.symbol(row).name)):
								fromFields[out] = true;
								fresh.push(out);
							default:
						}
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
					} else {
						clear(before);
						if (receiver)
							set(before, body.argument(0), true);
					}
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
		// A call `checkedRow` names checks its operand on every target, as a method call does.
		if (receiver.exists() && (checkedDereferences || opcode == IrOpcode.MethodCall || opcode == IrOpcode.Call))
			set(facts, receiver, true);
		switch opcode {
			case IrOpcode.NewObject, IrOpcode.ValueInit, IrOpcode.StaticClosure, IrOpcode.InstanceClosure,
				IrOpcode.ConstString:
				set(facts, body.output(row), true);
			case IrOpcode.FieldGet if (fields != null && fromFields[body.output(row)]):
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
