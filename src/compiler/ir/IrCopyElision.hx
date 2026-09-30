package compiler.ir;

import compiler.ir.Ir;
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
						case NewObject(copy, _):
							if (tryElide(blocks, block, position, copy))
								continue;
						default:
					}
				}
				position++;
			}
		}
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
			case NewObject(_, _):
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
		var writes:Array<Int> = [], feeders:Array<Int> = [], source:Null<IrValue> = null, callPosition = -1, argument = -1;
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
					case MethodCall(_, receiver, _, arguments) if (callPosition < 0 && uses == 1 && receiver.id != copy.id):
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
				case Branch(condition, _, _):
					if (condition.id == copy.id)
						return false;
				case Jump(_):
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
		if (callee == null || !readsOnly(callee.name, callee.parameter, [], 0) || !storesNothing(callee.name, false, [], 0))
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
				case NewObject(out, _):
					fresh.set(out.id, true);
				default:
			}
			if (position < from || position >= to)
				continue;
			switch instruction {
				case Call(_, _, _), MethodCall(_, _, _, _), CallClosure(_, _, _), CNativeCall(_, _, _), ArraySet(_, _, _), GlobalSet(_, _),
					MemoryStore(_, _, _), IteratorNext(_, _), BeginTry(_, _), EndTry(_), Catch(_):
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
		var swap = function(values:Array<IrValue>):Array<IrValue> return [for (value in values) value.id == from.id ? to : value];
		return switch instruction {
			case Call(out, name, arguments): Call(out, name, swap(arguments));
			case MethodCall(out, receiver, name, arguments): MethodCall(out, receiver, name, swap(arguments));
			default: instruction;
		};
	}

	/** The function a call resolves to and which of its parameters receives `argument`. */
	function calleeOf(instruction:IrInstruction, argument:Int):Null<{name:String, parameter:Int}> {
		switch instruction {
			case Call(_, name, _):
				return byName.exists(name) ? {name: name, parameter: argument} : null;
			case MethodCall(_, receiver, method, _):
				var target = valueMethod(receiver, method);
				return target != null && byName.exists(target) ? {name: target, parameter: argument} : null;
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
							if (arguments[position].id == parameter.id && !readsOnly(callee, position, visiting, depth + 1))
								ok = false;
					case MethodCall(_, receiver, method, arguments):
						var target = valueMethod(receiver, method);
						if (target == null)
							ok = false;
						else {
							if (receiver.id == parameter.id && !readsOnly(target, 0, visiting, depth + 1))
								ok = false;
							for (position in 0...arguments.length)
								if (arguments[position].id == parameter.id && !readsOnly(target, position + 1, visiting, depth + 1))
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
					case Branch(condition, _, _):
						if (condition.id == parameter.id)
							ok = false;
					case Jump(_):
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
					case NewObject(out, _):
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
					case ArraySet(_, _, _), GlobalSet(_, _), MemoryStore(_, _, _), CNativeCall(_, _, _), CallClosure(_, _, _):
						ok = false;
					case Call(_, callee, arguments):
						var constructor = StringTools.endsWith(callee, ".new") && arguments.length > 0 && fresh.exists(arguments[0].id);
						if (!storesNothing(callee, constructor, visiting, depth + 1))
							ok = false;
					case MethodCall(_, receiverValue, method, _):
						var target = valueMethod(receiverValue, method);
						if (target == null || !storesNothing(target, false, visiting, depth + 1))
							ok = false;
					default:
				}
		visiting.pop();
		return ok;
	}
}
