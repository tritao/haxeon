package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrPassScratch.IrValueMarks;
import compiler.ir.SourceProvenance.Located;

/**
 * Drops the copy of a value class instance made for an argument when the callee cannot tell the difference.
 *
 * A generated copy (see IrGenerator.copyValue) that is only passed to one call is replaced by its source when the
 * callee never writes to that parameter or lets it escape, the callee and everything it calls performs no stores
 * to existing objects, and nothing runs between the copy and the call. Then nothing can change the source while
 * the callee reads it, so passing it directly is unobservable.
 *
 * Every function an analysis looks at is reported through `consult`, so the inliner's cache can invalidate a caller
 * when one of them changes.
 */
@:allow(compiler.ir.IrBodyCopyElision)
class IrCopyElision {
	static inline var MaxDepth = 12;

	/** Runtime helpers that read their operands and store nothing that a value class could alias. */
	static final PureNatives = [
		"__string_concat",
		"__string_concat3",
		"__string_concat4",
		"__string_concat5",
		"__string_concat6",
		"__string_concat7",
		"__string_concat8",
		"__string_length",
		"__string_equal",
		"__string_from_int",
		"__string_from_f64",
		"__math_ceil",
		"__math_floor",
		"__math_fmod",
		"__std_int_f64"
	];

	final byName:Map<String, IrFunction>;
	final resolve:IrValue->String->Null<String>;
	final consult:String->Void;
	final resultDependencies:Map<String, Bool> = [];

	public function new(byName:Map<String, IrFunction>, resolve:IrValue->String->Null<String>, consult:String->Void) {
		this.byName = byName;
		this.resolve = resolve;
		this.consult = consult;
	}

	public function run(blocks:Array<IrBlock>):Void {
		for (block in blocks) {
			var position = 0;
			while (position < block.instructions.length) {
				var located = block.instructions[position];
				if (isValueCopy(located)) {
					switch located.value {
						case ValueInit(copy):
							if (tryElide(blocks, block, position, copy))
								continue;
						default:
					}
				}
				position++;
			}
		}
	}

	/**
	 * `run` on a body, in place: the callees it analyzes are `bodyOf`'s, a method call's target `resolve`'s for the receiver's
	 * type, and each function looked at is reported through `consult` as `run` reports it; whether any copy was dropped.
	 */
	public static function runBody(body:IrBody, bodyOf:String->Null<IrBody>, resolve:IrType->String->Null<String>,
			consult:String->Void, scratch:IrPassScratch):Bool
		return scratch.copyElision.run(body, bodyOf, resolve, consult);

	/** `hasCopies` on a body. */
	public static function hasCopiesBody(body:IrBody):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (isValueCopyRow(body, row))
					return true;
				row = body.nextRow(row);
			}
		}
		return false;
	}

	static function isValueCopyRow(body:IrBody, row:Int):Bool {
		if (body.opcode(row) != IrOpcode.ValueInit)
			return false;
		return switch body.provenance(row).origin {
			case CompilerGenerated(reason): reason == "value-copy";
			default: false;
		};
	}

	/** Whether `blocks` contains a generated value copy at all, so a function without other work can be skipped. */
	public static function hasCopies(blocks:Array<IrBlock>):Bool {
		for (block in blocks)
			for (located in block.instructions)
				if (isValueCopy(located))
					return true;
		return false;
	}

	static function isValueCopy(located:Located<IrInstruction>):Bool {
		switch located.value {
			case ValueInit(_):
			default:
				return false;
		}
		return switch located.provenance.origin {
			case CompilerGenerated(reason): reason == "value-copy";
			default: false;
		};
	}

	function tryElide(blocks:Array<IrBlock>, block:IrBlock, allocation:Int, copy:IrValue):Bool {
		// The copy's fields are written from reads of one source, and the copy has one other use: a call argument.
		var writes:Array<Int> = [],
			feeders:Array<Int> = [],
			source:Null<IrValue> = null,
			callPosition = -1,
			argument = -1;
		for (other in blocks)
			for (position in 0...other.instructions.length) {
				var instruction = other.instructions[position].value;
				var uses = 0;
				for (input in IrOperands.inputs(instruction))
					if (input.id == copy.id)
						uses++;
				switch instruction {
					case Phi(_, inputs):
						for (input in inputs)
							if (input.value.id == copy.id)
								return false;
					default:
				}
				if (uses == 0)
					continue;
				if (other != block || position <= allocation)
					return false;
				switch instruction {
					case FieldSet(target, name, value) if (target.id == copy.id && value.id != copy.id):
						var feeder = feederOf(block, allocation, position, value, name);
						if (feeder < 0)
							return false;
						var read = block.instructions[feeder].value;
						switch read {
							case FieldGet(_, from, _):
								if (source != null && source.id != from.id)
									return false;
								source = from;
							default: return false;
						}
						writes.push(position);
						feeders.push(feeder);
					case Call(_, _, arguments) if (callPosition < 0 && uses == 1):
						callPosition = position;
						argument = indexOf(arguments, copy);
					case MethodCall(_, receiver, _, arguments,
						_) if (callPosition < 0 && uses == 1 && receiver.id != copy.id):
						callPosition = position;
						argument = indexOf(arguments, copy) + 1;
					default:
						return false;
				}
			}
		for (other in blocks) {
			var terminator = other.terminator;
			if (terminator == null)
				continue;
			switch terminator.value {
				case Return(value), Throw(value), Rethrow(value):
					if (value.id == copy.id)
						return false;
				case Branch(condition, _, _), Switch(condition, _, _):
					if (condition.id == copy.id)
						return false;
				case Jump(_), Unreachable:
			}
		}
		if (source == null || callPosition < 0 || argument < 0)
			return false;
		var lastWrite = 0;
		for (position in writes)
			if (position > lastWrite)
				lastWrite = position;
		if (callPosition < lastWrite || !nothingRunsBetween(block, lastWrite + 1, callPosition))
			return false;
		var callee = calleeOf(block.instructions[callPosition].value, argument);
		if (callee == null
			|| resultDependsOnParameter(callee.name, callee.parameter, [], 0)
			|| !readsOnly(callee.name, callee.parameter, [], 0)
			|| !storesNothing(callee.name, false, [], 0))
			return false;
		// Pass the source itself, and drop the copy with the reads that fed it.
		var rewritten:Array<Located<IrInstruction>> = [];
		for (position in 0...block.instructions.length) {
			var current = block.instructions[position];
			if (position == allocation || writes.indexOf(position) >= 0 || feeders.indexOf(position) >= 0)
				continue;
			if (position == callPosition) {
				var replacement = replaceArgument(current.value, copy, source);
				rewritten.push(new Located(replacement, current.provenance));
				continue;
			}
			rewritten.push(current);
		}
		block.instructions.resize(0);
		for (kept in rewritten)
			block.instructions.push(kept);
		return true;
	}

	/** Whether the callee can return or throw an alias of a value copied from this argument. */
	function resultDependsOnParameter(name:String, index:Int, visiting:Array<String>, depth:Int):Bool {
		var fn = byName.get(name);
		if (fn == null || index >= fn.arguments.length || depth > MaxDepth)
			return true;
		var key = name + "#" + index;
		if (resultDependencies.exists(key))
			return resultDependencies.get(key);
		if (visiting.indexOf(key) >= 0)
			return true;
		consult(name);
		visiting.push(key);
		var parameter = fn.arguments[index],
			tainted:Map<Int, Bool> = [],
			fresh:Map<Int, Bool> = [];
		tainted.set(parameter.id, true);
		var changed = true, rounds = 0;
		while (changed && rounds++ < fn.blocks.length + 1) {
			changed = false;
			for (block in fn.blocks)
				for (located in block.instructions) {
					var instruction = located.value;
					switch instruction {
						case NewObject(out, _) | ValueInit(out):
							fresh.set(out.id, true);
						case FieldSet(target, _, value) if (fresh.exists(target.id) && tainted.exists(value.id)):
							if (!tainted.exists(target.id)) {
								tainted.set(target.id, true);
								changed = true;
							}
						case ArraySet(array, _, value) if (fresh.exists(array.id) && tainted.exists(value.id)):
							if (!tainted.exists(array.id)) {
								tainted.set(array.id, true);
								changed = true;
							}
						case Phi(out, inputs) if (canCarryIdentity(out.type)):
							for (input in inputs)
								if (tainted.exists(input.value.id) && !tainted.exists(out.id)) {
									tainted.set(out.id, true);
									changed = true;
								}
						default:
							var output = IrOperands.output(instruction);
							if (output != null && canCarryIdentity(output.type) && !tainted.exists(output.id)) {
								var depends = switch instruction {
									case Call(_, callee, arguments):
										var found = false;
										for (argument in 0...arguments.length)
											if (tainted.exists(arguments[argument].id)
												&& resultDependsOnParameter(callee.name, argument, visiting, depth + 1))
												found = true;
										found;
									case MethodCall(_, receiver, method, arguments, _):
										var target = valueMethod(receiver, method),
											found = target == null && tainted.exists(receiver.id);
										if (target != null
											&& tainted.exists(receiver.id)
											&& resultDependsOnParameter(target, 0, visiting, depth + 1))
											found = true;
										for (argument in 0...arguments.length)
											if (tainted.exists(arguments[argument].id)
												&& (target == null
												|| resultDependsOnParameter(target, argument + 1, visiting, depth + 1)))
												found = true;
										found;
									default:
										var found = false;
										for (input in IrOperands.inputs(instruction))
											if (tainted.exists(input.id))
												found = true;
										found;
								};
								if (depends) {
									tainted.set(output.id, true);
									changed = true;
								}
							}
					}
				}
		}
		var depends = false;
		for (block in fn.blocks) {
			var terminator = block.terminator;
			if (terminator == null)
				continue;
			switch terminator.value {
				case Return(value), Throw(value), Rethrow(value):
					if (tainted.exists(value.id))
						depends = true;
				case Branch(condition, _, _), Switch(condition, _, _):
				case Jump(_), Unreachable:
			}
		}
		visiting.pop();
		resultDependencies.set(key, depends);
		return depends;
	}

	static function canCarryIdentity(type:IrType):Bool
		return switch type {
			case Bytes, RawPtr, ManagedBytes, Dyn, TypeRef, Array(_), Enum(_), Obj(_), Abstract(_), Virtual(_),
				Iterator(_), Function(_, _): true;
			case Nullable(element): canCarryIdentity(element);
			case _: false;
		};

	/** The FieldGet of `field` whose value is `value`, when nothing else uses that value. */
	static function feederOf(block:IrBlock, allocation:Int, writePosition:Int, value:IrValue, field:String):Int {
		for (position in allocation + 1...writePosition)
			switch block.instructions[position].value {
				case FieldGet(out, _, name) if (out.id == value.id && name == field):
					var uses = 0;
					for (candidate in block.instructions)
						for (input in IrOperands.inputs(candidate.value))
							if (input.id == value.id)
								uses++;
					return uses == 1 ? position : -1;
				default:
			}
		return -1;
	}

	/** Only pure computation may sit between the copy and the call, or the callee could see a later state of the source. */
	static function nothingRunsBetween(block:IrBlock, from:Int, to:Int):Bool {
		var fresh:Map<Int, Bool> = [];
		for (position in 0...block.instructions.length) {
			var instruction = block.instructions[position].value;
			switch instruction {
				case NewObject(out, _) | ValueInit(out):
					fresh.set(out.id, true);
				default:
			}
			if (position < from || position >= to)
				continue;
			switch instruction {
				case Call(_, name, _) if (name.name == IrReceiverCheck.NAME || name.name == IrReferenceIdentity.NAME):
				case Call(_, _, _), MethodCall(_, _, _, _, _), CallClosure(_, _, _), CNativeCall(_, _, _),
					ArraySet(_, _, _), GlobalSet(_, _),
					MemoryStore(_, _, _), IteratorNext(_, _), BeginTry(_, _, _), EndTry(_, _), Catch(_):
					return false;
				case FieldSet(target, _, _):
					if (!fresh.exists(target.id))
						return false;
				default:
			}
		}
		return true;
	}

	static function indexOf(values:Array<IrValue>, value:IrValue):Int {
		for (index in 0...values.length)
			if (values[index].id == value.id)
				return index;
		return -1;
	}

	static function replaceArgument(instruction:IrInstruction, from:IrValue, to:IrValue):IrInstruction {
		var swap = function(values:Array<IrValue>):Array<IrValue> return [for (value in values) value.id == from.id
			? to : value];
		return switch instruction {
			case Call(out, name, arguments): Call(out, name, swap(arguments));
			case MethodCall(out, receiver, name, arguments, terminalReceiver): MethodCall(out, receiver, name,
				swap(arguments), terminalReceiver);
			default: instruction;
		};
	}

	/** The function a call resolves to and which of its parameters receives `argument`. */
	function calleeOf(instruction:IrInstruction, argument:Int):Null<{name:String, parameter:Int}> {
		switch instruction {
			case Call(_, name, _):
				return byName.exists(name.name) ? {
					name: name.name, parameter: argument
				} : null;
			case MethodCall(_, receiver, method, _, _):
				var target = valueMethod(receiver, method);
				return target != null && byName.exists(target) ? {
					name: target, parameter: argument
				} : null;
			default:
				return null;
		}
	}

	function valueMethod(receiver:IrValue, method:String):Null<String>
		return resolve(receiver, method);

	/** Parameter `index` of `name` is only read: never written, stored, returned or otherwise let out. */
	function readsOnly(name:String, index:Int, visiting:Array<String>, depth:Int):Bool {
		var fn = byName.get(name);
		if (fn == null || index >= fn.arguments.length || depth > MaxDepth)
			return false;
		var key = name + "#" + index;
		if (visiting.indexOf(key) >= 0)
			return false;
		consult(name);
		visiting.push(key);
		var parameter = fn.arguments[index], ok = true;
		for (block in fn.blocks) {
			for (located in block.instructions) {
				var instruction = located.value;
				switch instruction {
					case Phi(_, inputs):
						for (input in inputs)
							if (input.value.id == parameter.id)
								ok = false;
						continue;
					default:
				}
				var uses = 0;
				for (input in IrOperands.inputs(instruction))
					if (input.id == parameter.id)
						uses++;
				if (uses == 0)
					continue;
				switch instruction {
					case FieldGet(_, target, _) if (target.id == parameter.id):
					case Call(_, callee, arguments):
						for (position in 0...arguments.length)
							if (arguments[position].id == parameter.id
								&& !readsOnly(callee.name, position, visiting, depth + 1))
								ok = false;
					case MethodCall(_, receiver, method, arguments, _):
						var target = valueMethod(receiver, method);
						if (target == null)
							ok = false;
						else {
							if (receiver.id == parameter.id && !readsOnly(target, 0, visiting, depth + 1))
								ok = false;
							for (position in 0...arguments.length)
								if (arguments[position].id == parameter.id
									&& !readsOnly(target, position + 1, visiting, depth + 1))
									ok = false;
						}
					default:
						ok = false;
				}
			}
			var terminator = block.terminator;
			if (terminator != null)
				switch terminator.value {
					case Return(value), Throw(value), Rethrow(value):
						if (value.id == parameter.id)
							ok = false;
					case Branch(condition, _, _), Switch(condition, _, _):
						if (condition.id == parameter.id)
							ok = false;
					case Jump(_), Unreachable:
				}
		}
		visiting.pop();
		return ok;
	}

	/**
	 * `name` and everything it calls store only into objects it creates itself (and, for a constructor run on a new
	 * object, into that object), so no existing object changes while it runs.
	 */
	function storesNothing(name:String, allowThis:Bool, visiting:Array<String>, depth:Int):Bool {
		var fn = byName.get(name);
		if (fn == null)
			return PureNatives.indexOf(name) >= 0;
		if (depth > MaxDepth)
			return false;
		var key = name + (allowThis ? "#this" : "");
		if (visiting.indexOf(key) >= 0)
			return false;
		consult(name);
		visiting.push(key);
		var fresh:Map<Int, Bool> = [], ok = true;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case NewObject(out, _) | ValueInit(out):
						fresh.set(out.id, true);
					default:
				}
		var receiver = fn.arguments.length > 0 ? fn.arguments[0] : null;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case FieldSet(target, _, _):
						if (!fresh.exists(target.id) && !(allowThis && receiver != null && target.id == receiver.id))
							ok = false;
					case ArraySet(_, _, _), GlobalSet(_, _), MemoryStore(_, _, _), CNativeCall(_, _, _),
						CallClosure(_, _, _):
						ok = false;
					case Call(_, callee, arguments):
						var target = byName.get(callee.name);
						var constructor = target != null
							&& (switch target.result {
								case Void: true;
								default: false;
							})
								&& StringTools.endsWith(callee.name, ".new")
								&& arguments.length > 0
								&& fresh.exists(arguments[0].id);
						if (!storesNothing(callee.name, constructor, visiting, depth + 1))
							ok = false;
					case MethodCall(_, receiverValue, method, _, _):
						var target = valueMethod(receiverValue, method);
						if (target == null || !storesNothing(target, false, visiting, depth + 1))
							ok = false;
					default:
				}
		visiting.pop();
		return ok;
	}
}

/**
 * `IrCopyElision` on a body, in place, with the same result, and the same functions consulted in the same order. Its tables
 * are kept from one function to the next (`IrPassScratch.copyElision`).
 */
@:allow(compiler.ir.IrCopyElision)
class IrBodyCopyElision {
	var body:Null<IrBody> = null;
	var bodyOf:String->Null<IrBody> = noBody;
	var resolve:IrType->String->Null<String> = noTarget;
	var consult:String->Void = ignore;

	/** Per function, for the one being run: whether a callee's result depends on a parameter, by "name#index". */
	final resultDependencies:Map<String, Bool> = [];

	/** The keys of the callees being analyzed, innermost last. */
	final visiting:Array<String> = [];

	/** Per depth of the analysis of callees, the values tainted by the parameter there and the ones made fresh. */
	final tainted:Array<IrValueMarks> = [];

	final fresh:Array<IrValueMarks> = [];

	/** The copy's writes and the reads feeding them, as rows. */
	final writes:Array<Int> = [];

	final feeders:Array<Int> = [];

	/** Per row of the copy's block, its position there. */
	final positions:Array<Int> = [];

	/** Whether `resultDependencies` holds anything. */
	var remembered = false;

	final between = new IrValueMarks();

	/** The symbol ids of the helpers that may run between a copy and its call, looked up the first time they are needed. */
	var checkSymbol = -1;

	var identitySymbol = -1;

	public function new() {}

	function run(body:IrBody, bodyOf:String->Null<IrBody>, resolve:IrType->String->Null<String>,
			consult:String->Void):Bool {
		this.body = body;
		this.bodyOf = bodyOf;
		this.resolve = resolve;
		this.consult = consult;
		if (remembered) {
			resultDependencies.clear();
			remembered = false;
		}
		visiting.resize(0);
		var elided = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0 && !body.opcode(row).isTerminator()) {
				if (IrCopyElision.isValueCopyRow(body, row)) {
					// The rows before the copy stay, so the walk goes on from the row now after them.
					var previous = body.previousRow(row);
					if (tryElide(block, row, body.output(row))) {
						elided = true;
						row = previous >= 0 ? body.nextRow(previous) : body.firstRow(block);
						continue;
					}
				}
				row = body.nextRow(row);
			}
		}
		this.body = null;
		this.bodyOf = noBody;
		this.resolve = noTarget;
		this.consult = ignore;
		return elided;
	}

	// What the functions are between runs, so the tables keep no caller's closures alive.

	static function noBody(name:String):Null<IrBody>
		return null;

	static function noTarget(type:IrType, method:String):Null<String>
		return null;

	static function ignore(name:String):Void {}

	function marks(tables:Array<IrValueMarks>, depth:Int):IrValueMarks {
		while (tables.length <= depth)
			tables.push(new IrValueMarks());
		var result = tables[depth];
		result.clear();
		return result;
	}

	/** `IrCopyElision.tryElide`: positions within the copy's block are counted in `positions`. */
	function tryElide(home:Int, allocation:Int, copy:IrValueId):Bool {
		var body = this.body, source = -1, callRow = -1, argument = -1;
		writes.resize(0);
		feeders.resize(0);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), after = false;
			while (row >= 0) {
				var opcode = body.opcode(row), count = body.operandCount(row);
				if (opcode.isTerminator()) {
					if (count > 0 && body.operand(row, 0) == copy)
						return false;
				} else if (opcode == IrOpcode.Phi) {
					for (index in 0...count)
						if (body.operand(row, index) == copy)
							return false;
				} else {
					var uses = 0;
					for (index in 0...count)
						if (body.operand(row, index) == copy)
							uses++;
					if (uses > 0) {
						if (block != home || !after)
							return false;
						switch opcode {
							case IrOpcode.FieldSet if (body.operand(row, 0) == copy && body.operand(row, 1) != copy):
								var feeder = feederOf(home, allocation, row, body.operand(row, 1), body.aux(row));
								if (feeder < 0)
									return false;
								var from:Int = body.operand(feeder, 0);
								if (source >= 0 && source != from)
									return false;
								source = from;
								writes.push(row);
								feeders.push(feeder);
							case IrOpcode.Call if (callRow < 0 && uses == 1):
								callRow = row;
								argument = operandIndex(row, 0, copy);
							case IrOpcode.MethodCall if (callRow < 0 && uses == 1 && body.operand(row, 0) != copy):
								callRow = row;
								argument = operandIndex(row, 1, copy);
							default:
								return false;
						}
					}
				}
				if (row == allocation)
					after = true;
				row = body.nextRow(row);
			}
		}
		if (source < 0 || callRow < 0 || argument < 0)
			return false;
		while (positions.length < body.rowLimit())
			positions.push(-1);
		var position = 0, row = body.firstRow(home);
		while (row >= 0) {
			positions[row] = position++;
			row = body.nextRow(row);
		}
		var lastWrite = 0;
		for (write in writes)
			if (positions[write] > lastWrite)
				lastWrite = positions[write];
		if (positions[callRow] < lastWrite || !nothingRunsBetween(home, lastWrite + 1, positions[callRow]))
			return false;
		var calleeName:Null<String> = null;
		switch body.opcode(callRow) {
			case IrOpcode.Call:
				var name = body.symbol(callRow).name;
				if (bodyOf(name) != null)
					calleeName = name;
			case IrOpcode.MethodCall:
				var target = resolve(body.valueType(body.operand(callRow, 0)), body.symbol(callRow).name);
				if (target != null && bodyOf(target) != null)
					calleeName = target;
			default:
		}
		if (calleeName == null
			|| resultDependsOnParameter(calleeName, argument, 0)
			|| !readsOnly(calleeName, argument, 0)
			|| !storesNothing(calleeName, false, 0))
			return false;
		// Pass the source itself, and drop the copy with the reads that fed it.
		for (index in (body.opcode(callRow) == IrOpcode.MethodCall ? 1 : 0)...body.operandCount(callRow))
			if (body.operand(callRow, index) == copy)
				body.setOperand(callRow, index, IrValueId.of(source));
		body.removeRow(home, allocation);
		for (write in writes)
			body.removeRow(home, write);
		for (feeder in feeders)
			body.removeRow(home, feeder);
		return true;
	}

	/** The first operand of `row` from `from` on that is `value`, or -1: the parameter a call passes it to. */
	function operandIndex(row:Int, from:Int, value:IrValueId):Int {
		for (index in from...body.operandCount(row))
			if (body.operand(row, index) == value)
				return index;
		return -1;
	}

	/** `IrCopyElision.feederOf`. */
	function feederOf(block:Int, allocation:Int, write:Int, value:IrValueId, field:Int):Int {
		var row = body.nextRow(allocation);
		while (row != write) {
			if (body.opcode(row) == IrOpcode.FieldGet && body.output(row) == value && body.aux(row) == field) {
				var uses = 0, candidate = body.firstRow(block);
				while (candidate >= 0) {
					var opcode = body.opcode(candidate);
					if (!opcode.isTerminator() && opcode != IrOpcode.Phi)
						for (index in 0...body.operandCount(candidate))
							if (body.operand(candidate, index) == value)
								uses++;
					candidate = body.nextRow(candidate);
				}
				return uses == 1 ? row : -1;
			}
			row = body.nextRow(row);
		}
		return -1;
	}

	/** `IrCopyElision.nothingRunsBetween`. */
	function nothingRunsBetween(block:Int, from:Int, to:Int):Bool {
		if (checkSymbol < 0) {
			checkSymbol = IrSymbol.of(IrReceiverCheck.NAME).id;
			identitySymbol = IrSymbol.of(IrReferenceIdentity.NAME).id;
		}
		var fresh = between;
		fresh.clear();
		var row = body.firstRow(block), position = 0;
		while (row >= 0 && !body.opcode(row).isTerminator()) {
			var opcode = body.opcode(row), at = position++;
			if (opcode == IrOpcode.NewObject || opcode == IrOpcode.ValueInit)
				fresh.add(body.output(row));
			if (at >= from && at < to)
				switch opcode {
					case IrOpcode.Call if (body.aux(row) == checkSymbol || body.aux(row) == identitySymbol):
					case IrOpcode.Call, IrOpcode.MethodCall, IrOpcode.CallClosure, IrOpcode.CNativeCall,
						IrOpcode.ArraySet, IrOpcode.GlobalSet, IrOpcode.MemoryStore, IrOpcode.IteratorNext,
						IrOpcode.BeginTry, IrOpcode.EndTry,
						IrOpcode.Catch:
						return false;
					case IrOpcode.FieldSet:
						if (!fresh.has(body.operand(row, 0)))
							return false;
					default:
				}
			row = body.nextRow(row);
		}
		return true;
	}

	/** `IrCopyElision.resultDependsOnParameter`. */
	function resultDependsOnParameter(name:String, index:Int, depth:Int):Bool {
		var fn = bodyOf(name);
		if (fn == null || index >= fn.argumentCount() || depth > IrCopyElision.MaxDepth)
			return true;
		var key = name + "#" + index;
		if (resultDependencies.exists(key))
			return resultDependencies.get(key);
		if (visiting.indexOf(key) >= 0)
			return true;
		consult(name);
		visiting.push(key);
		var tainted = marks(this.tainted, depth), fresh = marks(this.fresh, depth);
		tainted.add(fn.argument(index));
		var changed = true, rounds = 0;
		while (changed && rounds++ < fn.blockCount() + 1) {
			changed = false;
			for (block in 0...fn.blockCount()) {
				var row = fn.firstRow(block);
				while (row >= 0 && !fn.opcode(row).isTerminator()) {
					var opcode = fn.opcode(row), out = fn.output(row);
					switch opcode {
						case IrOpcode.NewObject, IrOpcode.ValueInit:
							fresh.add(out);
						case IrOpcode.FieldSet | IrOpcode.ArraySet:
							var target = fn.operand(row, 0),
								value = fn.operand(row, opcode == IrOpcode.FieldSet ? 1 : 2);
							if (fresh.has(target) && tainted.has(value) && tainted.add(target))
								changed = true;
						case IrOpcode.Phi if (IrCopyElision.canCarryIdentity(fn.valueType(out))):
							for (input in 0...fn.operandCount(row))
								if (tainted.has(fn.operand(row, input)) && tainted.add(out))
									changed = true;
						default:
							if (out.exists() && IrCopyElision.canCarryIdentity(fn.valueType(out)) && !tainted.has(out)
								&& outputDepends(fn, row, tainted, depth)) {
								tainted.add(out);
								changed = true;
							}
					}
					row = fn.nextRow(row);
				}
			}
		}
		var depends = false;
		for (block in 0...fn.blockCount()) {
			var terminator = fn.terminatorRow(block);
			if (terminator < 0)
				continue;
			switch fn.opcode(terminator) {
				case IrOpcode.Return, IrOpcode.Throw, IrOpcode.Rethrow:
					if (tainted.has(fn.operand(terminator, 0)))
						depends = true;
				default:
			}
		}
		visiting.pop();
		resultDependencies.set(key, depends);
		remembered = true;
		return depends;
	}

	/** Whether the output of `row` of `fn` can carry a tainted value's identity. */
	function outputDepends(fn:IrBody, row:Int, tainted:IrValueMarks, depth:Int):Bool {
		var found = false;
		switch fn.opcode(row) {
			case IrOpcode.Call:
				var callee = fn.symbol(row).name;
				for (argument in 0...fn.operandCount(row))
					if (tainted.has(fn.operand(row, argument))
						&& resultDependsOnParameter(callee, argument, depth + 1))
						found = true;
			case IrOpcode.MethodCall:
				var receiver = fn.operand(row, 0),
					target = resolve(fn.valueType(receiver), fn.symbol(row).name);
				found = target == null && tainted.has(receiver);
				if (target != null && tainted.has(receiver) && resultDependsOnParameter(target, 0, depth + 1))
					found = true;
				for (argument in 1...fn.operandCount(row))
					if (tainted.has(fn.operand(row, argument))
						&& (target == null || resultDependsOnParameter(target, argument, depth + 1)))
						found = true;
			default:
				for (index in 0...fn.operandCount(row))
					if (tainted.has(fn.operand(row, index)))
						found = true;
		}
		return found;
	}

	/** `IrCopyElision.readsOnly`. */
	function readsOnly(name:String, index:Int, depth:Int):Bool {
		var fn = bodyOf(name);
		if (fn == null || index >= fn.argumentCount() || depth > IrCopyElision.MaxDepth)
			return false;
		var key = name + "#" + index;
		if (visiting.indexOf(key) >= 0)
			return false;
		consult(name);
		visiting.push(key);
		var parameter = fn.argument(index), ok = true;
		for (block in 0...fn.blockCount()) {
			var row = fn.firstRow(block);
			while (row >= 0) {
				var opcode = fn.opcode(row), count = fn.operandCount(row);
				if (opcode.isTerminator()) {
					if (count > 0 && fn.operand(row, 0) == parameter)
						ok = false;
				} else if (opcode == IrOpcode.Phi) {
					for (input in 0...count)
						if (fn.operand(row, input) == parameter)
							ok = false;
				} else {
					var uses = 0;
					for (input in 0...count)
						if (fn.operand(row, input) == parameter)
							uses++;
					if (uses > 0)
						switch opcode {
							case IrOpcode.FieldGet:
							case IrOpcode.Call:
								var callee = fn.symbol(row).name;
								for (position in 0...count)
									if (fn.operand(row, position) == parameter
										&& !readsOnly(callee, position, depth + 1))
										ok = false;
							case IrOpcode.MethodCall:
								var receiver = fn.operand(row, 0),
									target = resolve(fn.valueType(receiver), fn.symbol(row).name);
								if (target == null)
									ok = false;
								else {
									if (receiver == parameter && !readsOnly(target, 0, depth + 1))
										ok = false;
									for (position in 1...count)
										if (fn.operand(row, position) == parameter
											&& !readsOnly(target, position, depth + 1))
											ok = false;
								}
							default:
								ok = false;
						}
				}
				row = fn.nextRow(row);
			}
		}
		visiting.pop();
		return ok;
	}

	/** `IrCopyElision.storesNothing`. */
	function storesNothing(name:String, allowThis:Bool, depth:Int):Bool {
		var fn = bodyOf(name);
		if (fn == null)
			return IrCopyElision.PureNatives.indexOf(name) >= 0;
		if (depth > IrCopyElision.MaxDepth)
			return false;
		var key = name + (allowThis ? "#this" : "");
		if (visiting.indexOf(key) >= 0)
			return false;
		consult(name);
		visiting.push(key);
		var fresh = marks(this.fresh, depth), ok = true;
		for (block in 0...fn.blockCount()) {
			var row = fn.firstRow(block);
			while (row >= 0) {
				var opcode = fn.opcode(row);
				if (opcode == IrOpcode.NewObject || opcode == IrOpcode.ValueInit)
					fresh.add(fn.output(row));
				row = fn.nextRow(row);
			}
		}
		var receiver = fn.argumentCount() > 0 ? fn.argument(0) : IrValueId.of(-1);
		for (block in 0...fn.blockCount()) {
			var row = fn.firstRow(block);
			while (row >= 0) {
				switch fn.opcode(row) {
					case IrOpcode.FieldSet:
						var target = fn.operand(row, 0);
						if (!fresh.has(target) && !(allowThis && receiver.exists() && target == receiver))
							ok = false;
					case IrOpcode.ArraySet, IrOpcode.GlobalSet, IrOpcode.MemoryStore, IrOpcode.CNativeCall,
						IrOpcode.CallClosure:
						ok = false;
					case IrOpcode.Call:
						var callee = fn.symbol(row).name, target = bodyOf(callee);
						var constructor = target != null
							&& (switch target.types.type(target.result) {
								case Void: true;
								default: false;
							})
								&& StringTools.endsWith(callee, ".new")
								&& fn.operandCount(row) > 0
								&& fresh.has(fn.operand(row, 0));
						if (!storesNothing(callee, constructor, depth + 1))
							ok = false;
					case IrOpcode.MethodCall:
						var target = resolve(fn.valueType(fn.operand(row, 0)), fn.symbol(row).name);
						if (target == null || !storesNothing(target, false, depth + 1))
							ok = false;
					default:
				}
				row = fn.nextRow(row);
			}
		}
		visiting.pop();
		return ok;
	}
}
