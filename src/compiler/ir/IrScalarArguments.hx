package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.IrInlineValueLayout.IrInlineValueSlot;

/** A direct call `rewriteCalls` replaces by one to a scalar clone, decided on the body before any row of it changes. */
private typedef ScalarCallPlan = {
	final block:Int;
	final row:Int;

	/** Whether the call takes the clone; one that does not may still have taken an id for a receiver check. */
	final qualifies:Bool;

	final check:Bool;
	final name:String;
	final pinned:Bool;
	final arguments:Array<IrValueId>;
}

/**
 * Direct-call specialization for nonescaping value arguments; HashLink also supports scalar result slots. On IR bodies
 * (docs/design/IR_CORE_COLUMNS.md, migration): value joins are split first (`IrValuePhiScalarization`), then each candidate is
 * cloned with its value arguments expanded into slots, and direct calls are redirected to the clones in place.
 */
class IrScalarArguments {
	public static inline final PREFIX = "$scalar-arguments:";

	/** Raw result slots and traced leaf carriers may cross only the verified private callable ABI. */
	public static function isPrivateClosureType(type:IrType):Bool
		return switch type {
			case Function(arguments, result):
				var found = IrHlScalarRef.element(result) != null || IrValueLaneReference.isCarrier(result);
				for (argument in arguments)
					if (IrHlScalarRef.element(argument) != null || IrValueLaneReference.isCarrier(argument))
						found = true;
				found;
			default: false;
		};

	final program:IrProgram;
	final objects:Map<String, IrObject>;
	final table:IrObjectTable;
	final layouts:IrInlineValueLayout;
	final resolution:IrMethodResolution;
	final types:IrTypeIds;
	final scratch:IrPassScratch;
	final retained:Bool;
	final argumentsOnly:Bool;
	final byName:Map<String, IrFunction>;
	final candidates:Map<String, IrBody> = [];
	final pinnedCandidates:Map<String, IrBody> = [];
	final freshOnly:Map<String, Bool> = [];
	final terminalOnly:Map<String, Bool> = [];
	final methodNames:Map<String, Bool> = [];

	/**
	 * Splits value joins and rewrites `program`'s functions and calls for the scalar ABI, on bodies made with `types` (those of
	 * the program's bodies when not given, `IrTypeIds.ofFunctions`), which this stage encodes when it is the pipeline's first over
	 * bodies. A function that changes becomes its edited body: a frozen copy when a session keeps the stage's functions
	 * (`retained`), else the body edited in place. With `argumentsOnly` (Wasm), no result slots and no receiver checks.
	 */
	public static function rewrite(program:IrProgram, argumentsOnly:Bool = false, ?types:IrTypeIds,
			?scratch:IrPassScratch,
			retained = true):Void {
		if (types == null)
			types = IrTypeIds.ofFunctions(program.functions);
		if (scratch == null)
			scratch = new IrPassScratch();
		// Call rewriting judges value arguments by their uses, which a value join hides.
		IrValuePhiScalarization.rewriteBodies(program, types, scratch, retained);
		new IrScalarArguments(program, argumentsOnly, types, scratch, retained).run();
	}

	function new(program:IrProgram, argumentsOnly:Bool, types:IrTypeIds, scratch:IrPassScratch, retained:Bool) {
		this.program = program;
		this.argumentsOnly = argumentsOnly;
		this.types = types;
		this.scratch = scratch;
		this.retained = retained;
		objects = [for (object in program.objects) object.name => object];
		table = IrObjectTable.of(objects);
		layouts = new IrInlineValueLayout(table);
		resolution = IrMethodResolution.of(program);
		byName = [for (fn in program.functions) fn.name => fn];
	}

	function run():Void {
		var bodies = [for (fn in program.functions) fn.bodyIn(types, scratch.bodyBuilder, retained)];
		if (!retained)
			for (fn in program.functions)
				fn.releaseDecoded();
		// Typed closure signatures are an ABI decision, including forwarding closures.
		// Keep their scalar entry points available before IrScalarClosures rewrites
		// indirect calls; judging those calls against the boxed ABI here creates a
		// cycle that prevents allocation-free forwarding of value arguments/results.
		var closureTargets:Map<String, Bool> = [];
		if (!argumentsOnly)
			for (body in bodies)
				for (block in 0...body.blockCount()) {
					var row = body.firstRow(block);
					while (row >= 0) {
						switch body.opcode(row) {
							case IrOpcode.StaticClosure, IrOpcode.InstanceClosure:
								closureTargets.set(body.symbol(row).name, true);
							default:
						}
						row = body.nextRow(row);
					}
				}
		// Methods that call out may snapshot only a fresh receiver: a field place can be changed by an alias
		// while the method runs, and must keep its original receiver ABI.
		for (body in bodies) {
			if (!IrScalarAbiEligibility.permits(body.kind, false))
				continue;
			var resultType = types.type(body.result),
				hasValue = isValue(resultType),
				eligible = true,
				pinnedEligible = !argumentsOnly,
				pinnedHasValue = hasValue,
				argumentCount = 0,
				pinnedArgumentCount = 1;
			if (argumentsOnly && hasValue)
				eligible = false;
			if (hasValue) {
				if (!hasScalarLayout(resultType))
					eligible = false;
				argumentCount += slots(resultType).length;
				pinnedArgumentCount += slots(resultType).length;
			}
			for (index in 0...body.argumentCount()) {
				var arg = body.argument(index), type = body.valueType(arg);
				if (!isValue(type)) {
					argumentCount++;
					if (index != 0)
						pinnedArgumentCount++;
					continue;
				}
				hasValue = true;
				if (index != 0)
					pinnedHasValue = true;
				if (body.valueName(arg) == "this" && !receiverReadOnly(body)) {
					if (receiverSnapshotOnly(body, arg, null))
						freshOnly.set(body.name, true);
					else if (receiverSnapshotOnly(body, arg, null, true)) {
						freshOnly.set(body.name, true);
						terminalOnly.set(body.name, true);
					} else
						eligible = false;
				}
				if (!hasScalarLayout(type)) {
					eligible = false;
					if (index != 0)
						pinnedEligible = false;
				}
				argumentCount += slots(type).length;
				if (index != 0)
					pinnedArgumentCount += slots(type).length;
			}
			// The HashLink JIT accepts at most 256 arguments per emitted call. Dynamic calls retain the original ABI.
			if (argumentCount > 256)
				eligible = false;
			if (hasValue && eligible)
				candidates.set(body.name, body);
			if (pinnedArgumentCount > 256 || isValue(resultType) && !hasScalarLayout(resultType))
				pinnedEligible = false;
			if (pinnedEligible && pinnedHasValue && body.argumentCount() > 0
				&& body.valueName(body.argument(0)) == "this" && isValue(body.valueType(body.argument(0))))
				pinnedCandidates.set(body.name, body);
		}
		for (object in program.objects)
			for (method in object.methods)
				if (candidates.exists(method.functionName.name) || pinnedCandidates.exists(method.functionName.name))
					methodNames.set(method.name, true);
		// Do not redirect a call if reconstructing its value arguments would allocate in the clone. In particular,
		// handler edges can keep an otherwise field-only value alive across blocks.
		var clones:Map<String, IrBody> = [], pinnedClones:Map<String, IrBody> = [], changed = true;
		while (changed) {
			changed = false;
			clones = [];
			pinnedClones = [];
			var allCandidates = candidates.copy();
			for (name in pinnedCandidates.keys())
				allCandidates.set(name, pinnedCandidates.get(name));
			for (body in bodies)
				if (candidates.exists(body.name)) {
					var retainedValue = false;
					for (index in 0...body.argumentCount()) {
						var arg = body.argument(index);
						if (isValue(body.valueType(arg))) {
							if (!fieldOnly(body, arg, allCandidates))
								retainedValue = true;
							if (freshOnly.exists(body.name)
								&& body.valueName(arg) == "this"
								&& !receiverSnapshotOnly(body, arg, candidates, terminalOnly.exists(body.name)))
								retainedValue = true;
						}
					}
					var specialized = specialize(body, false);
					if (keepsValue(body, specialized, 0))
						retainedValue = true;
					if (retainedValue && !closureTargets.exists(body.name)) {
						candidates.remove(body.name);
						changed = true;
					} else
						clones.set(body.name, specialized);
				}
			for (body in bodies)
				if (pinnedCandidates.exists(body.name)) {
					var retainedValue = false;
					for (index in 1...body.argumentCount()) {
						var arg = body.argument(index);
						if (isValue(body.valueType(arg)) && !fieldOnly(body, arg, allCandidates))
							retainedValue = true;
					}
					var specialized = specialize(body, true);
					if (keepsValue(body, specialized, 1))
						retainedValue = true;
					if (retainedValue) {
						pinnedCandidates.remove(body.name);
						changed = true;
					} else
						pinnedClones.set(body.name, specialized);
				}
		}
		if (!candidates.keys().hasNext() && !pinnedCandidates.keys().hasNext())
			return;
		var rewritten:Array<IrFunction> = [];
		for (index in 0...bodies.length)
			rewritten.push(rewriteFunction(program.functions[index], bodies[index]));
		for (body in bodies)
			if (candidates.exists(body.name))
				rewritten.push(publish(clones.get(body.name)));
		// Receiver-preserving variants are only useful when a rewritten call selects one.
		// Keep their transitive dependencies, but do not publish every possible variant into
		// the program: an unused variant still consumes module and JIT metadata.
		var pinnedByName:Map<String, IrBody> = [],
			needed:Map<String, Bool> = [],
			pending:Array<String> = [];
		for (clone in pinnedClones)
			pinnedByName.set(clone.name, clone);
		function discover(body:IrBody):Void {
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					switch body.opcode(row) {
						case IrOpcode.Call, IrOpcode.StaticClosure, IrOpcode.InstanceClosure:
							var name = body.symbol(row).name;
							if (pinnedByName.exists(name) && !needed.exists(name)) {
								needed.set(name, true);
								pending.push(name);
							}
						default:
					}
					row = body.nextRow(row);
				}
			}
		}
		for (fn in rewritten)
			discover(fn.bodyIn(types, scratch.bodyBuilder, retained));
		while (pending.length > 0) {
			var name = pending.pop(), dependency = pinnedByName.get(name);
			if (dependency == null)
				throw new InternalError('Missing receiver-preserving clone "$name"');
			discover(dependency);
		}
		for (body in bodies)
			if (pinnedCandidates.exists(body.name)) {
				var clone = pinnedClones.get(body.name);
				if (clone == null)
					throw new InternalError('Missing receiver-preserving clone for "${body.name}"');
				if (needed.exists(clone.name))
					rewritten.push(publish(clone));
			}
		program.functions = rewritten;
	}

	/** `body`'s clone for the scalar ABI, its calls rewritten, its value joins split and its value allocations replaced. */
	function specialize(body:IrBody, preserveReceiver:Bool):IrBody {
		var specialized = clone(body, preserveReceiver);
		rewriteCalls(specialized);
		// Scalar call rewriting can introduce value constructions into a join. Split those joins before
		// judging whether the specialized callee can keep its value arguments and result in registers.
		specialized = IrValuePhiScalarization.runBody(specialized, objects, table, layouts, null, scratch);
		specialized.keepNamedValues(scratch.namedValues);
		IrScalarReplacement.runBody(specialized, table, scratch, true, true);
		specialized.keepNamedValues(scratch.namedValues);
		return specialized;
	}

	/**
	 * Whether `specialized`, the clone of `body`, still makes one of the value arguments from `first` on, or its value result, as
	 * an object that is not a register place, or receives a value result from a call.
	 */
	function keepsValue(body:IrBody, specialized:IrBody, first:Int):Bool {
		var places = new IrScalarValuePlaces(specialized, name -> objects.get(name)),
			resultType = types.type(body.result),
			valueResult = isValue(resultType);
		for (block in 0...specialized.blockCount()) {
			var row = specialized.firstRow(block);
			while (row >= 0) {
				switch specialized.opcode(row) {
					case IrOpcode.ValueInit:
						var out = specialized.output(row),
							name = IrTypeTools.valueObjectName(specialized.valueType(out));
						for (index in first...body.argumentCount()) {
							var arg = body.argument(index);
							if (isValue(body.valueType(arg)) && (out:Int) == (arg:Int) && !places.contains(out))
								return true;
						}
						if (valueResult && Type.enumEq(resultType, Obj(name)) && !places.contains(out))
							return true;
					case IrOpcode.Call, IrOpcode.MethodCall, IrOpcode.CallClosure:
						if (valueResult && isValue(specialized.valueType(specialized.output(row))))
							return true;
					default:
				}
				row = specialized.nextRow(row);
			}
		}
		return false;
	}

	/** The function a clone this stage made is: frozen when a session keeps it. */
	function publish(body:IrBody):IrFunction
		return retained ? IrFunction.ofBody(body.freeze(true, scratch.bodyBuilder)) : IrFunction.ofOwnedBody(body);

	/** `fn`, whose body is `body`, with its direct calls to candidates redirected: `fn` itself when it has none. */
	function rewriteFunction(fn:IrFunction, body:IrBody):IrFunction {
		var plans = planCalls(body);
		if (plans.length == 0)
			return fn;
		var edited = body.forEditing(scratch.bodyBuilder);
		if (edited != body)
			plans = planCalls(edited);
		applyCalls(edited, plans);
		return retained ? IrFunction.ofBody(edited.freeze(true, scratch.bodyBuilder)) : IrFunction.ofOwnedBody(edited);
	}

	/** Redirects the direct calls of `body`, which this stage owns, in place. */
	function rewriteCalls(body:IrBody):Void {
		var plans = planCalls(body);
		if (plans.length > 0)
			applyCalls(body, plans);
	}

	static function isValueIn(type:IrType, objects:Map<String, IrObject>):Bool
		return switch type {
			case Obj(name): objects.exists(name) && objects.get(name).isValue;
			default: false;
		};

	inline function isValue(type:IrType):Bool
		return isValueIn(type, objects);

	function hasScalarLayout(type:IrType):Bool {
		for (slot in slots(type))
			if (slot.isPresence)
				return false;
		return true;
	}

	inline function slots(type:IrType):Array<IrInlineValueSlot>
		return layouts.slots(type);

	inline function argumentType(body:IrBody, index:Int):IrType
		return body.valueType(body.argument(index));

	/** `root` and the value fields read from it, transitively. */
	function aliasesOf(body:IrBody, root:IrValueId):Map<Int, Bool> {
		var aliases:Map<Int, Bool> = [(root:Int) => true], changed = true;
		while (changed) {
			changed = false;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					if (body.opcode(row) == IrOpcode.FieldGet) {
						var out = body.output(row);
						if (aliases.exists(body.operand(row, 0)) && isValue(body.valueType(out))
							&& !aliases.exists(out)) {
							aliases.set(out, true);
							changed = true;
						}
					}
					row = body.nextRow(row);
				}
			}
		}
		return aliases;
	}

	/** Whether a terminator row lets one of `aliases` escape: returned (unless `valueReturn`), thrown or branched on. */
	static function terminatorEscapes(body:IrBody, row:Int, aliases:Map<Int, Bool>, valueReturn:Bool):Bool
		return switch body.opcode(row) {
			case IrOpcode.Return: !valueReturn && aliases.exists(body.operand(row, 0));
			case IrOpcode.Throw, IrOpcode.Rethrow, IrOpcode.Branch,
				IrOpcode.Switch: aliases.exists(body.operand(row, 0));
			default: false;
		};

	function fieldOnly(body:IrBody, arg:IrValueId, candidates:Map<String, IrBody>):Bool {
		var aliases = aliasesOf(body, arg), valueResult = isValue(types.type(body.result));
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var opcode = body.opcode(row);
				if (opcode.isTerminator()) {
					if (terminatorEscapes(body, row, aliases, valueResult))
						return false;
					row = body.nextRow(row);
					continue;
				}
				var uses = false;
				for (index in 0...body.operandCount(row))
					if (aliases.exists(body.operand(row, index)))
						uses = true;
				if (opcode == IrOpcode.Phi && uses)
					return false;
				if (uses)
					switch opcode {
						case IrOpcode.FieldGet if (aliases.exists(body.operand(row, 0))):
						case IrOpcode.FieldSet if (aliases.exists(body.operand(row, 0))
							&& !aliases.exists(body.operand(row, 1))):
						case IrOpcode.Call if (candidates.exists(body.symbol(row).name)):
							var target = candidates.get(body.symbol(row).name);
							for (index in 0...body.operandCount(row))
								if (aliases.exists(body.operand(row, index)) && !isValue(argumentType(target, index)))
									return false;
						case IrOpcode.MethodCall if (methodNames.exists(body.symbol(row).name)):
							var name = resolveMethod(body.valueType(body.operand(row, 0)), body.symbol(row).name);
							if (name == null || !candidates.exists(name))
								return false;
							var target = candidates.get(name);
							for (index in 1...body.operandCount(row))
								if (aliases.exists(body.operand(row, index)) && !isValue(argumentType(target, index)))
									return false;
						default:
							return false;
					}
				row = body.nextRow(row);
			}
		}
		return true;
	}

	/** A place receiver may be changed by aliases during a callback, so only specialize a receiver that cannot write or call out. */
	static function receiverReadOnly(body:IrBody):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.Call, IrOpcode.CNativeCall, IrOpcode.MethodCall, IrOpcode.CallClosure,
						IrOpcode.GlobalSet,
						IrOpcode.FieldSet, IrOpcode.ArraySet, IrOpcode.MemoryStore, IrOpcode.InstanceClosure,
						IrOpcode.StaticClosure:
						return false;
					default:
				}
				row = body.nextRow(row);
			}
		}
		return true;
	}

	/** A fresh receiver is safe to snapshot when the method only reads its fields or calls other safe value resolution.
	 * The first pass discovers possible resolution; the candidate fixpoint checks every transitive receiver call.
	 */
	function receiverSnapshotOnly(body:IrBody, receiver:IrValueId, candidates:Null<Map<String, IrBody>>,
			allowWrites:Bool = false):Bool {
		var aliases = aliasesOf(body, receiver);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var opcode = body.opcode(row);
				if (opcode.isTerminator()) {
					if (terminatorEscapes(body, row, aliases, false))
						return false;
					row = body.nextRow(row);
					continue;
				}
				for (input in 0...body.operandCount(row))
					if (aliases.exists(body.operand(row, input)))
						switch opcode {
							case IrOpcode.FieldGet if (aliases.exists(body.operand(row, 0))):
							case IrOpcode.FieldSet if (allowWrites && aliases.exists(body.operand(row, 0))
								&& !aliases.exists(body.operand(row, 1))):
							case IrOpcode.MethodCall if (aliases.exists(body.operand(row, 0))):
								if (hasAlias(body, row, aliases))
									return false;
								var name = resolveMethod(body.valueType(body.operand(row, 0)), body.symbol(row).name);
								if (name == null || candidates != null && !candidates.exists(name))
									return false;
							default:
								return false;
						}
				row = body.nextRow(row);
			}
		}
		return true;
	}

	/** Prove that a fresh value and its nested places do not escape. With a proven snapshot-only method, repeated calls
	 * to that same method are safe; otherwise retain the one-call restriction. The fresh receiver is non-null.
	 */
	function freshReceiver(body:IrBody, receiver:IrValueId, ?safeMethod:String):Bool {
		if (!isValue(body.valueType(receiver)))
			return false;
		var aliases = aliasesOf(body, receiver), fresh = false, uses = 0;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var opcode = body.opcode(row);
				if (opcode.isTerminator()) {
					if (terminatorEscapes(body, row, aliases, false))
						return false;
					row = body.nextRow(row);
					continue;
				}
				switch opcode {
					case IrOpcode.NewObject, IrOpcode.ValueInit, IrOpcode.Call, IrOpcode.MethodCall,
						IrOpcode.CallClosure
						if ((body.output(row):Int) == (receiver:Int)):
						fresh = true;
					default:
				}
				for (input in 0...body.operandCount(row))
					if (aliases.exists(body.operand(row, input)))
						switch opcode {
							case IrOpcode.FieldSet if (aliases.exists(body.operand(row, 0))
								&& !aliases.exists(body.operand(row, 1))):
							case IrOpcode.FieldGet if (aliases.exists(body.operand(row, 0))):
							case IrOpcode.MethodCall if ((body.operand(row, 0):Int) == (receiver:Int)
								&& !hasAlias(body, row, aliases)
								&& (safeMethod == null
								|| resolveMethod(body.valueType(body.operand(row, 0)), body.symbol(row).name)
								== safeMethod)):
								uses++;
							case IrOpcode.Call if (body.operandCount(row) > 0
								&& (body.operand(row, 0):Int) == (receiver:Int)
								&& !hasAlias(body, row, aliases)
								&& (safeMethod == null || body.symbol(row).name == safeMethod)):
								uses++;
							default:
								return false;
						}
				row = body.nextRow(row);
			}
		}
		return fresh && (uses == 1 || safeMethod != null && uses > 1);
	}

	/** Repeated calls are safe only when every receiver use is the same proven snapshot-only method. */
	function freshForCandidate(body:IrBody, receiver:IrValueId, name:String):Bool {
		var candidate = candidates.get(name);
		var safe = candidate != null && candidate.argumentCount() > 0
			&& candidate.valueName(candidate.argument(0)) == "this" ? name : null;
		return freshReceiver(body, receiver, safe);
	}

	/** A terminal call has no surviving value place to receive its receiver mutations. Scoped disposal and a
	 * temporary value copy carry this guarantee; every call on the fresh place must agree. */
	function freshForTerminal(body:IrBody, receiver:IrValueId, name:String):Bool {
		if (!isValue(body.valueType(receiver)))
			return false;
		var aliases = aliasesOf(body, receiver), fresh = false, calls = 0;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var opcode = body.opcode(row);
				if (opcode.isTerminator()) {
					if (terminatorEscapes(body, row, aliases, false))
						return false;
					row = body.nextRow(row);
					continue;
				}
				switch opcode {
					case IrOpcode.NewObject, IrOpcode.ValueInit, IrOpcode.Call, IrOpcode.MethodCall,
						IrOpcode.CallClosure
						if ((body.output(row):Int) == (receiver:Int)):
						fresh = true;
					case IrOpcode.Phi:
						for (input in 0...body.operandCount(row))
							if (aliases.exists(body.operand(row, input)))
								return false;
					default:
				}
				for (input in 0...body.operandCount(row))
					if (aliases.exists(body.operand(row, input)))
						switch opcode {
							case IrOpcode.FieldSet if (aliases.exists(body.operand(row, 0))
								&& !aliases.exists(body.operand(row, 1))):
							case IrOpcode.FieldGet if (aliases.exists(body.operand(row, 0))):
							case IrOpcode.MethodCall if ((body.aux(row) & 1) != 0
								&& (body.operand(row, 0):Int) == (receiver:Int)
								&& !hasAlias(body, row, aliases)
								&& resolveMethod(body.valueType(body.operand(row, 0)), body.symbol(row).name) == name):
								calls++;
							default:
								return false;
						}
				row = body.nextRow(row);
			}
		}
		return fresh && calls > 0;
	}

	/** Whether an operand of `row` after its first is one of `aliases`. */
	static function hasAlias(body:IrBody, row:Int, aliases:Map<Int, Bool>):Bool {
		for (index in 1...body.operandCount(row))
			if (aliases.exists(body.operand(row, index)))
				return true;
		return false;
	}

	/**
	 * A new body, the copy of `source` for the scalar ABI: each value argument (but the receiver when `preserveReceiver`) becomes
	 * one argument per slot, written into the value at entry, and a value result one reference argument per slot that each
	 * return stores through. Values numbered from `source`'s next, as the decoding would be.
	 */
	function clone(source:IrBody, preserveReceiver:Bool):IrBody {
		var builder = scratch.bodyBuilder, next = source.presentValueLimit();
		builder.startFrom(source);
		builder.clearArguments();
		var origin = SourceProvenance.generated("scalar-argument");
		function define(name:String, type:IrType):IrValueId {
			var id = IrValueId.of(next++);
			builder.defineValue(id, name, types.id(type));
			return id;
		}
		var resultType = types.type(source.result),
			returnSlots = isValue(resultType) ? slots(resultType) : [],
			outputs:Array<IrValueId> = [];
		// The entry rows, written once the entry block begins: opcode, output, auxiliary field, and up to two operands (-1 for none).
		var entry:Array<Int> = [];
		for (index in 0...source.argumentCount()) {
			var arg = source.argument(index), type = source.valueType(arg);
			if (preserveReceiver && index == 0 || !isValue(type)) {
				builder.addArgument(arg);
				continue;
			}
			entry.push(IrOpcode.ValueInit);
			entry.push(arg);
			entry.push(0);
			entry.push(-1);
			entry.push(-1);
			for (slot in slots(type)) {
				var leaf = define(source.valueName(arg) + "." + slot.path.join("."), slot.type);
				builder.addArgument(leaf);
				var target = arg, targetType = type;
				for (position in 0...slot.path.length - 1) {
					var field = fieldOf(targetType, slot.path[position]), child = define(field.name, field.type);
					entry.push(IrOpcode.FieldGet);
					entry.push(child);
					entry.push(IrSymbol.of(field.name).id);
					entry.push(target);
					entry.push(-1);
					target = child;
					targetType = field.type;
				}
				entry.push(IrOpcode.FieldSet);
				entry.push(-1);
				entry.push(IrSymbol.of(slot.path[slot.path.length - 1]).id);
				entry.push(target);
				entry.push(leaf);
			}
		}
		for (slot in returnSlots) {
			var output = define("$hl:result:" + slot.path.join("."), IrHlScalarRef.type(slot.type));
			outputs.push(output);
			builder.addArgument(output);
		}
		for (block in 0...source.blockCount()) {
			builder.beginBlock(source.blockId(block));
			if (block == 0) {
				var at = 0;
				while (at < entry.length) {
					if (entry[at + 3] >= 0)
						builder.operandId(IrValueId.of(entry[at + 3]));
					if (entry[at + 4] >= 0)
						builder.operandId(IrValueId.of(entry[at + 4]));
					builder.row((entry[at]:IrOpcode), entry[at + 1], entry[at + 2], origin);
					at += 5;
				}
			}
			var row = source.firstRow(block);
			while (row >= 0) {
				if (returnSlots.length == 0 || source.opcode(row) != IrOpcode.Return) {
					builder.copyRow(source, row);
					row = source.nextRow(row);
					continue;
				}
				var where = source.provenance(row), value = source.operand(row, 0), leaves:Array<IrValueId> = [];
				for (slot in returnSlots) {
					var current = value, currentType = source.valueType(value);
					for (part in slot.path) {
						var field = fieldOf(currentType, part), leaf = define(part, field.type);
						builder.operandId(current);
						builder.row(IrOpcode.FieldGet, leaf, IrSymbol.of(part).id, where);
						current = leaf;
						currentType = field.type;
					}
					leaves.push(current);
				}
				for (slot in 0...outputs.length) {
					var ignored = define("$hl:result-store", Void);
					builder.operandId(outputs[slot]);
					builder.operandId(leaves[slot]);
					builder.row(IrOpcode.Call, ignored, IrSymbol.of(IrHlScalarRef.STORE).id, where);
				}
				var done = define("$hl:result-done", Void);
				builder.row(IrOpcode.ConstVoid, done, 0, where);
				builder.operandId(done);
				builder.row(IrOpcode.Return, -1, 0, where);
				row = source.nextRow(row);
			}
		}
		for (index in 0...source.bindingCount())
			builder.copyBinding(source, index, source.bindingValue(index));
		return builder.finishNamed(PREFIX + (preserveReceiver ? "$receiver:" : "") + source.name, ScalarArguments,
			returnSlots.length > 0 ? types.id(Void) : source.result, source.inlineHint, Reachable);
	}

	/**
	 * The direct calls of `body` to redirect to a clone, in row order, decided on the body as it is: a closure call to a known
	 * candidate, a method call that resolves to one, or a call of one.
	 */
	function planCalls(body:IrBody):Array<ScalarCallPlan> {
		var plans:Array<ScalarCallPlan> = [];
		var closures:Null<Map<Int, {name:String, receiver:Null<IrValueId>}>> = null;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.StaticClosure, IrOpcode.InstanceClosure:
						var name = body.symbol(row).name;
						if (candidates.exists(name) || pinnedCandidates.exists(name)) {
							if (closures == null)
								closures = [];
							closures.set(body.output(row), {
								name: name,
								receiver: body.opcode(row) == IrOpcode.InstanceClosure ? body.operand(row, 0) : null
							});
						}
					default:
				}
				row = body.nextRow(row);
			}
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.Call, IrOpcode.MethodCall, IrOpcode.CallClosure:
						var plan = planCall(body, block, row, closures);
						if (plan != null)
							plans.push(plan);
					default:
				}
				row = body.nextRow(row);
			}
		}
		return plans;
	}

	function planCall(body:IrBody, block:Int, row:Int,
			closures:Null<Map<Int, {name:String, receiver:Null<IrValueId>}>>):Null<ScalarCallPlan> {
		var terminalFresh = false, check = false, name = "", arguments:Array<IrValueId>;
		var provenance = body.provenance(row);
		switch body.opcode(row) {
			case IrOpcode.CallClosure if (closures != null && closures.exists(body.operand(row, 0))):
				var binding = closures.get(body.operand(row, 0));
				if (binding == null)
					return null;
				name = binding.name;
				arguments = [];
				if (binding.receiver != null)
					arguments.push(binding.receiver);
				for (index in 1...body.operandCount(row))
					arguments.push(body.operand(row, index));
			case IrOpcode.MethodCall if (methodNames.exists(body.symbol(row).name)):
				var receiver = body.operand(row, 0),
					resolved = resolveMethod(body.valueType(receiver), body.symbol(row).name);
				if (resolved == null || !candidates.exists(resolved) && !pinnedCandidates.exists(resolved))
					return null;
				if (terminalOnly.exists(resolved) && (body.aux(row) & 1) != 0)
					terminalFresh = freshForTerminal(body, receiver, resolved);
				var ordinaryFresh = !terminalOnly.exists(resolved) && freshForCandidate(body, receiver, resolved);
				if (((argumentsOnly || freshOnly.exists(resolved))
					&& !pinnedCandidates.exists(resolved)
					&& !terminalFresh
					&& !ordinaryFresh
					&& !(argumentsOnly
					&& !terminalOnly.exists(resolved)
					&& safeArrayEquality(provenance, body))))
					return null;
				check = !argumentsOnly && !terminalFresh && !ordinaryFresh;
				name = resolved;
				arguments = [];
				for (index in 0...body.operandCount(row))
					arguments.push(body.operand(row, index));
			case IrOpcode.Call:
				name = body.symbol(row).name;
				if (!candidates.exists(name) && !pinnedCandidates.exists(name))
					return null;
				arguments = [for (index in 0...body.operandCount(row)) body.operand(row, index)];
			default:
				return null;
		}
		var qualifies = (candidates.exists(name) || pinnedCandidates.exists(name))
			&& (pinnedCandidates.exists(name)
			|| !freshOnly.exists(name)
			|| terminalFresh
			|| !terminalOnly.exists(name)
			&& arguments.length > 0
			&& freshForCandidate(body, arguments[0], name)
			|| argumentsOnly
			&& !terminalOnly.exists(name)
			&& safeArrayEquality(provenance, body))
			&& (!argumentsOnly
			|| terminalFresh
			|| !terminalOnly.exists(name)
			&& (safeArrayEquality(provenance, body)
			|| freshValueArguments(body, arguments)));
		if (!qualifies)
			return check ? {
				block: block,
				row: row,
				qualifies: false,
				check: true,
				name: name,
				pinned: false,
				arguments: arguments
			} : null;
		var pinned = pinnedCandidates.exists(name)
			&& (!candidates.exists(name)
			|| freshOnly.exists(name)
			&& !terminalFresh
			&& arguments.length > 0
			&& (terminalOnly.exists(name) || !freshForCandidate(body, arguments[0], name)));
		return {
			block: block,
			row: row,
			qualifies: true,
			check: check,
			name: name,
			pinned: pinned,
			arguments: arguments
		};
	}

	/**
	 * Replaces each planned call of `body` by the call of its clone: value arguments read field by field, a reference per result
	 * slot, and the value result made again from them. New values are numbered from the body's next, as the decoding would be; a
	 * plan that only took an id for a receiver check still takes it.
	 */
	function applyCalls(body:IrBody, plans:Array<ScalarCallPlan>):Void {
		var next = body.presentValueLimit();
		function fresh(name:String, type:IrType):IrValueId {
			var id = next++;
			while (body.valueLimit() < id)
				body.skipValue();
			return body.newValueAt(id, name, body.typeId(type));
		}
		for (plan in plans) {
			if (!plan.qualifies) {
				next++;
				continue;
			}
			var block = plan.block,
				row = plan.row,
				where = body.provenance(row),
				out = body.output(row),
				arguments = plan.arguments;
			inline function emit(opcode:IrOpcode, output:IrValueId, aux:Int):Void
				body.linkBefore(block, row, body.endRow(opcode, output, aux, where));
			if (plan.check) {
				var checked = fresh("$hl:receiver-check", Void);
				body.beginRow();
				body.pushOperand(arguments[0]);
				emit(IrOpcode.Call, checked, IrSymbol.of(IrReceiverCheck.NAME).id);
			}
			var target = plan.pinned ? pinnedCandidates.get(plan.name) : candidates.get(plan.name),
				expanded:Array<IrValueId> = [];
			if (target == null)
				throw new InternalError('Missing scalar call target "${plan.name}"');
			for (index in 0...arguments.length) {
				var arg = arguments[index];
				if (plan.pinned && index == 0 || !isValue(argumentType(target, index))) {
					expanded.push(arg);
					continue;
				}
				var argName = body.valueName(arg), argType = body.valueType(arg);
				for (slot in slots(argType)) {
					var current = arg, currentType = argType;
					for (part in slot.path) {
						var field = fieldOf(currentType, part), leaf = fresh(argName + "." + part, field.type);
						body.beginRow();
						body.pushOperand(current);
						emit(IrOpcode.FieldGet, leaf, IrSymbol.of(part).id);
						current = leaf;
						currentType = field.type;
					}
					expanded.push(current);
				}
			}
			var targetResult = types.type(target.result),
				returnSlots = isValue(targetResult) ? slots(targetResult) : [],
				references:Array<IrValueId> = [];
			for (slot in returnSlots) {
				var zero = fresh("$hl:result-zero", slot.type),
					reference = fresh("$hl:result-ref", IrHlScalarRef.type(slot.type));
				body.beginRow();
				switch slot.type {
					case I32, I64: emit(IrOpcode.ConstInt, zero, 0);
					case F32, F64: emit(IrOpcode.ConstFloat, zero, body.addFloat(0.0));
					case Bool: emit(IrOpcode.ConstBool, zero, 0);
					default: emit(IrOpcode.ConstNull, zero, 0);
				}
				body.beginRow();
				body.pushOperand(zero);
				emit(IrOpcode.Call, reference, IrSymbol.of(IrHlScalarRef.ADDRESS).id);
				references.push(reference);
				expanded.push(reference);
			}
			var targetName = IrSymbol.of(PREFIX + (plan.pinned ? "$receiver:" : "") + plan.name).id;
			if (returnSlots.length == 0) {
				body.beginRow();
				for (value in expanded)
					body.pushOperand(value);
				emit(IrOpcode.Call, out, targetName);
			} else {
				var ignored = fresh("$hl:result-call", Void);
				body.beginRow();
				for (value in expanded)
					body.pushOperand(value);
				emit(IrOpcode.Call, ignored, targetName);
				var outType = body.valueType(out);
				switch outType {
					case Obj(_):
					default: throw new InternalError("Invalid scalar result");
				}
				body.beginRow();
				emit(IrOpcode.ValueInit, out, 0);
				for (index in 0...returnSlots.length) {
					var slot = returnSlots[index],
						leaf = fresh("$hl:result-leaf", slot.type),
						current = out,
						currentType = outType;
					body.beginRow();
					body.pushOperand(references[index]);
					emit(IrOpcode.Call, leaf, IrSymbol.of(IrHlScalarRef.LOAD).id);
					for (position in 0...slot.path.length - 1) {
						var field = fieldOf(currentType, slot.path[position]), child = fresh(field.name, field.type);
						body.beginRow();
						body.pushOperand(current);
						emit(IrOpcode.FieldGet, child, IrSymbol.of(field.name).id);
						current = child;
						currentType = field.type;
					}
					body.beginRow();
					body.pushOperand(current);
					body.pushOperand(leaf);
					emit(IrOpcode.FieldSet, IrValueId.of(-1), IrSymbol.of(slot.path[slot.path.length - 1]).id);
				}
			}
			body.removeRow(block, row);
		}
		body.keepNamedValues(scratch.namedValues);
	}

	/** The Wasm scalar ABI reads fields at the call site. Only an unaliased value is stable there;
		other arguments retain their owning snapshots until the backend can preserve their evaluation point. */
	function freshValueArguments(body:IrBody, arguments:Array<IrValueId>):Bool {
		for (argument in arguments)
			if (isValue(body.valueType(argument)) && !freshReceiver(body, argument))
				return false;
		return true;
	}

	/** The function `name` is a copy of for the scalar call ABI, or null when it is not such a copy. */
	public static function originalName(name:String):Null<String>
		return StringTools.startsWith(name, PREFIX) ? name.substr(PREFIX.length) : null;

	function safeArrayEquality(provenance:SourceProvenance, body:IrBody):Bool {
		if (IrProviders.isValueEqualityNamed(body.name, body.kind, byName))
			return true;
		return switch provenance.origin {
			case CompilerGenerated("value-array-index-equality"): true;
			default: false;
		};
	}

	function fieldOf(type:IrType, name:String):IrObjectField {
		var objectName = switch type {
			case Obj(value): value;
			default: throw new InternalError("Invalid scalar field owner");
		};
		var object = objects.get(objectName);
		if (object != null)
			for (field in object.fields)
				if (field.name == name)
					return field;
		throw new InternalError('Missing scalar field $objectName.$name');
	}

	function resolveMethod(type:IrType, method:String):Null<String> {
		var name = switch type {
			case Obj(value): value;
			default: return null;
		};
		var root = objects.get(name);
		if (root == null)
			return null;
		if (root.isValue)
			return resolution.find(name, method);
		return resolution.uniqueImplementation(name, method);
	}
}
