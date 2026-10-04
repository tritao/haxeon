package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrFunctionStateCodec;

/** An inlined function together with everything its result depended on. */
class InlineMemo {
	public final source:IrFunction;

	/** Which program-wide fingerprint (see `IrInlineCache.fingerprintId`) the result was inlined under. */
	public final fingerprint:Int;

	/** The pristine callee functions consulted, transitively; the result is valid only while all are unchanged. */
	public final dependencies:Array<IrFunction>;

	public final result:IrFunction;

	public function new(source:IrFunction, fingerprint:Int, dependencies:Array<IrFunction>, result:IrFunction) {
		this.source = source;
		this.fingerprint = fingerprint;
		this.dependencies = dependencies;
		this.result = result;
	}
}

/**
 * Per-session inliner state. `memo` keeps a function's inlined form while it and every callee it looked at are
 * unchanged, so unchanged functions keep their identity between compiles; `published` is the inlined form each
 * function had after the last successful compile, which is what a patch has to be computed against.
 */
class IrInlineCache {
	public var memo:Map<String, InlineMemo> = [];
	public var published:Map<String, IrFunction> = [];

	var lastFingerprint:Null<String> = null;
	var lastFingerprintId = 0;

	public function new() {}

	/**
	 * A number that names a program-wide fingerprint: the same while the fingerprint text is unchanged, a new one when it
	 * changes. A memo entry is checked against it for every function of the program on every compile, which as a
	 * comparison of the (large, freshly built) text cost a third of an incremental compile.
	 */
	public function fingerprintId(text:String):Int {
		if (lastFingerprint == null || lastFingerprint != text) {
			lastFingerprint = text;
			lastFingerprintId++;
		}
		return lastFingerprintId;
	}

	public function copy():IrInlineCache {
		var result = new IrInlineCache();
		for (name => entry in memo)
			result.memo.set(name, entry);
		for (name => fn in published)
			result.published.set(name, fn);
		result.lastFingerprint = lastFingerprint;
		result.lastFingerprintId = lastFingerprintId;
		return result;
	}
}

/**
 * Inlines small callees into their callers. See docs/INLINING_AND_VALUE_TYPES.md.
 *
 * The pass never mutates a function it was given: cached IR is shared between compiles and transaction snapshots, so a
 * caller that changes is rebuilt as a new IrFunction and unchanged callers keep their identity. Decisions depend only
 * on IR content and on the (sorted) order of `program.functions`, so an incremental build matches a clean one.
 */
class IrInliner {
	/** Instruction budget for a callee without an `inline` hint. */
	public static inline var SmallBudget = 24;

	/** Instruction budget for a callee declared `inline`. */
	public static inline var HintBudget = 96;

	static inline var MaxBlocks = 12;
	static inline var MaxInlinesPerFunction = 48;
	static inline var MaxFunctionInstructions = 3000;
	static inline var MaxChainDepth = 24;

	/**
	 * On unless `HAXEON_INLINE=0`. The build tool derives its worker identity and cache fingerprint from the same
	 * variable (`CompilerClient.inlineOption`, `ActionFingerprint.appendCompilerOptions`); keep the three in step.
	 */
	public static var enabled:Bool = Sys.getEnv("HAXEON_INLINE") != "0";

	/** Set for targets that store a value class field inline in its parent and hand out a pointer into it (HashLink). */
	public static var packedValueFields:Bool = false;

	final byName:Map<String, IrFunction> = [];
	final done:Map<String, IrFunction> = [];
	final dependenciesOf:Map<String, Array<IrFunction>> = [];
	final impure:Map<String, Bool> = [];
	final visiting:Map<String, Bool> = [];
	final objects:Map<String, IrObject> = [];
	final entryPoint:String;

	/** Direct subclasses of each class, for resolving a virtual call when every override agrees. */
	final subclasses:Map<String, Array<String>> = [];

	final cache:IrInlineCache;
	final fingerprint:Int;
	final nextMemo:Map<String, InlineMemo> = [];

	/** One entry per function being inlined: the callee functions it has consulted so far. */
	final frames:Array<Map<String, IrFunction>> = [];

	final frameNames:Array<String> = [];
	final frameImpure:Array<Bool> = [];
	var depth = 0;

	function new(program:IrProgram, cache:IrInlineCache) {
		entryPoint = program.entryPoint;
		this.cache = cache;
		for (fn in program.functions)
			byName.set(fn.name, fn);
		var lines:Array<String> = [
			entryPoint,
			"packed=" + packedValueFields,
			"inline=" + enabled,
			"loadstore=" + IrLoadStoreForwarding.enabled
		];
		for (object in program.objects) {
			objects.set(object.name, object);
			if (object.base != null) {
				var base = Std.string(object.base);
				if (!subclasses.exists(base))
					subclasses.set(base, []);
				subclasses.get(base).push(object.name);
			}
			if (!object.isValue)
				lines.push(object.name
					+ "<"
					+ Std.string(object.base)
					+ ":"
					+ [for (method in object.methods) method.name + "=" + method.functionName].join(","));
			if (object.isValue)
				lines.push(object.name + ":" + [for (method in object.methods) method.name + "=" + method.functionName].join(",") + ":" + [
					for (field in object.fields)
						field.name + "=" + Std.string(field.type)
				].join(","));
		}
		lines.sort(Reflect.compare);
		fingerprint = cache.fingerprintId(lines.join(";"));
	}

	/**
	 * Replaces every function that had a call inlined and returns the names whose inlined form differs from the one
	 * published by the previous compile. Those functions must be re-lowered and patched even when their own source did
	 * not change, because a callee they inlined did.
	 */
	public static function run(program:IrProgram, cache:IrInlineCache):Array<String> {
		var inliner = new IrInliner(program, cache),
			functions:Array<IrFunction> = [],
			changed:Array<String> = [];
		var published:Map<String, IrFunction> = [];
		for (fn in program.functions) {
			var result = inliner.inlinedVersion(fn.name),
				previous = cache.published.get(fn.name);
			if (previous != null && previous != result) {
				// Generated functions (initializers, the entry) are rebuilt on every compile; only different bytes count.
				if (sameBytes(previous, result))
					result = previous;
				else
					changed.push(fn.name);
			} else if (previous == null)
				changed.push(fn.name);
			functions.push(result);
			published.set(fn.name, result);
		}
		program.functions = functions;
		cache.memo = inliner.nextMemo;
		cache.published = published;
		return changed;
	}

	/** Whether both encode to the same bytes; a function that cannot be encoded (an unterminated dead block) counts as different. */
	static function sameBytes(a:IrFunction, b:IrFunction):Bool {
		try {
			return IrFunctionStateCodec.encode(a).compare(IrFunctionStateCodec.encode(b)) == 0;
		} catch (_:Dynamic) {
			return false;
		}
	}

	function inlinedVersion(name:String):IrFunction {
		var known = done.get(name);
		if (known != null) {
			consultResult(name);
			return known;
		}
		var original = byName.get(name);
		if (original == null)
			return null;
		var memo = cache.memo.get(name);
		if (memo != null && memo.source == original && memo.fingerprint == fingerprint && dependenciesCurrent(memo.dependencies)) {
			done.set(name, memo.result);
			dependenciesOf.set(name, memo.dependencies);
			nextMemo.set(name, memo);
			consultResult(name);
			return memo.result;
		}
		visiting.set(name, true);
		depth++;
		frames.push([]);
		frameNames.push(name);
		frameImpure.push(false);
		var result = enabled ? inlineCalls(original) : original;
		if (IrLoadStoreForwarding.enabled)
			result = IrLoadStoreForwarding.run(result, objects);
		var consulted = frames.pop(), isImpure = frameImpure.pop();
		frameNames.pop();
		depth--;
		visiting.remove(name);
		var dependencies:Array<IrFunction> = [];
		var names = [for (dependencyName in consulted.keys()) dependencyName];
		names.sort(Reflect.compare);
		for (dependencyName in names)
			dependencies.push(consulted.get(dependencyName));
		done.set(name, result);
		dependenciesOf.set(name, dependencies);
		if (isImpure)
			impure.set(name, true);
		else
			nextMemo.set(name, new InlineMemo(original, fingerprint, dependencies, result));
		consultResult(name);
		return result;
	}

	function dependenciesCurrent(dependencies:Array<IrFunction>):Bool {
		for (dependency in dependencies)
			if (byName.get(dependency.name) != dependency)
				return false;
		return true;
	}

	/** Records `name`'s pristine body and everything its inlined form depended on in the function being inlined. */
	function consultResult(name:String):Void {
		if (frames.length == 0)
			return;
		var frame = frames[frames.length - 1];
		var original = byName.get(name);
		if (original != null)
			frame.set(name, original);
		var dependencies = dependenciesOf.get(name);
		if (dependencies != null)
			for (dependency in dependencies)
				frame.set(dependency.name, dependency);
		if (impure.exists(name))
			frameImpure[frameImpure.length - 1] = true;
	}

	/** The function a call resolves to when it can be inlined, else null. */
	function calleeOf(instruction:IrInstruction):Null<IrFunction> {
		var target:Null<String> = null, argumentCount = -1;
		switch instruction {
			case Call(_, functionName, arguments):
				target = functionName;
				argumentCount = arguments.length;
			case MethodCall(_, object, methodName, arguments):
				target = resolveMethod(object, methodName);
				argumentCount = arguments.length + 1;
			default:
		}
		if (target == null || !byName.exists(target))
			return null;
		var original = byName.get(target);
		if (frames.length > 0)
			frames[frames.length - 1].set(target, original);
		if (visiting.exists(target)) {
			// Skipping the function being inlined is context-free; skipping an ancestor depends on the order of the walk.
			if (frameNames.length == 0 || frameNames[frameNames.length - 1] != target)
				frameImpure[frameImpure.length - 1] = true;
			return null;
		}
		if (depth > MaxChainDepth) {
			if (frameImpure.length > 0)
				frameImpure[frameImpure.length - 1] = true;
			return null;
		}
		if (original.arguments.length != argumentCount || !looksInlinable(original))
			return null;
		var candidate = inlinedVersion(target);
		if (candidate == null || !fits(candidate))
			return null;
		// HashLink's JIT keeps registers only inside a basic block, so a branching body costs more spliced in than called;
		// only a straight-line body, or one the author marked inline, is worth it.
		return isStraightLine(candidate) || candidate.inlineHint ? candidate : null;
	}

	/**
	 * The function a method call reaches, when the receiver's class and all its subclasses run the same one. A value
	 * class is final, so its methods always resolve. Anything else can be overridden only by a class in this program:
	 * patches cannot add classes, so a live module cannot introduce another override.
	 */
	public function resolveMethod(receiver:IrValue, method:String):Null<String> {
		var typeName = switch receiver.type {
			case Obj(name): name;
			default: return null;
		};
		var target:Null<String> = null, work = [typeName], visited = 0;
		while (work.length > 0 && visited < 256) {
			var name = work.pop();
			visited++;
			var implementation = implementationIn(name, method);
			if (implementation == null || (target != null && target != implementation))
				return null;
			target = implementation;
			var children = subclasses.get(name);
			if (children != null)
				for (child in children)
					work.push(child);
		}
		return work.length > 0 ? null : target;
	}

	function implementationIn(typeName:String, method:String):Null<String> {
		var name:Null<String> = typeName, steps = 0;
		while (name != null && steps < 64) {
			var descriptor = objects.get(name);
			if (descriptor == null)
				return null;
			for (candidate in descriptor.methods)
				if (candidate.name == method)
					return candidate.functionName;
			name = descriptor.base == null ? null : Std.string(descriptor.base);
			steps++;
		}
		return null;
	}

	/** Cheap syntactic screen on the original body, before the callee's own calls are inlined. */
	function looksInlinable(fn:IrFunction):Bool {
		if (StringTools.startsWith(fn.name, "__") || fn.name == entryPoint)
			return false;
		return countInstructions(fn) <= (fn.inlineHint ? HintBudget : SmallBudget) * 2;
	}

	function fits(fn:IrFunction):Bool {
		if (fn.blocks.length > MaxBlocks || countInstructions(fn) > (fn.inlineHint ? HintBudget : SmallBudget))
			return false;
		var returns = 0;
		for (block in fn.blocks) {
			for (located in block.instructions)
				switch located.value {
					case BeginTry(_, _), EndTry(_), Catch(_):
						return false;
					default:
				}
			var terminator = block.terminator;
			if (terminator == null)
				return false;
			switch terminator.value {
				case Return(_):
					returns++;
				default:
			}
		}
		return returns > 0;
	}

	static function isStraightLine(fn:IrFunction):Bool {
		if (fn.blocks.length != 1)
			return false;
		var terminator = fn.blocks[0].terminator;
		if (terminator == null)
			return false;
		return switch terminator.value {
			case Return(_): true;
			default: false;
		};
	}

	static function countInstructions(fn:IrFunction):Int {
		var total = 0;
		for (block in fn.blocks)
			total += block.instructions.length;
		return total;
	}

	function inlineCalls(fn:IrFunction):IrFunction {
		// Runtime helpers (initializers, the entry) are patched specially; nothing is ever inlined into them.
		if (StringTools.startsWith(fn.name, "__"))
			return fn;
		var found = false;
		for (block in fn.blocks) {
			for (located in block.instructions)
				if (calleeOf(located.value) != null) {
					found = true;
					break;
				}
			if (found)
				break;
		}
		if (!found && !IrCopyElision.hasCopies(fn.blocks))
			return fn;
		var blocks:Array<IrBlock> = [], nextValue = 0, nextBlock = 0;
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) {
				copy.instructions.push(located);
				var output = IrOperands.output(located.value);
				if (output != null && output.id >= nextValue)
					nextValue = output.id + 1;
				for (input in IrOperands.inputs(located.value))
					if (input.id >= nextValue)
						nextValue = input.id + 1;
			}
			copy.terminator = block.terminator;
			blocks.push(copy);
			if (block.id >= nextBlock)
				nextBlock = block.id + 1;
		}
		for (argument in fn.arguments)
			if (argument.id >= nextValue)
				nextValue = argument.id + 1;
		var index = 0, inlines = 0, instructions = countInstructions(fn), substitutions:Map<Int, IrValue> = [];
		while (index < blocks.length) {
			var block = blocks[index], position = -1, callee:Null<IrFunction> = null;
			if (inlines < MaxInlinesPerFunction && instructions < MaxFunctionInstructions)
				for (candidate in 0...block.instructions.length) {
					callee = calleeOf(block.instructions[candidate].value);
					if (callee != null) {
						position = candidate;
						break;
					}
				}
			if (callee == null) {
				index++;
				continue;
			}
			inlines++;
			instructions += countInstructions(callee);
			if (isStraightLine(callee)) {
				// Splice into the calling block: no new block, no phi. Rescan the block; the spliced calls were not candidates.
				nextValue = splice(block, position, callee, substitutions, nextValue);
				continue;
			}
			var expansion = expand(blocks, index, position, callee, nextValue, nextBlock);
			nextValue = expansion.nextValue;
			nextBlock = expansion.nextBlock;
			// Continue with the first inlined block; calls left in it were not candidates.
			index++;
		}
		var bindings = fn.debugBindings;
		if (substitutions.keys().hasNext())
			bindings = substitute(blocks, substitutions, bindings);
		var replaced = IrScalarReplacement.run(blocks, objects, nextValue);
		if (packedValueFields)
			replaced = {substitutions: replaced.substitutions, nextValue: IrScalarReplacement.constructInPlace(blocks, objects, replaced.nextValue)};
		if (replaced.substitutions.keys().hasNext())
			bindings = substitute(blocks, replaced.substitutions, bindings);
		var consult = function(name:String):Void {
			var original = byName.get(name);
			if (original != null && frames.length > 0)
				frames[frames.length - 1].set(name, original);
		};
		new IrCopyElision(byName, resolveMethod, consult).run(blocks);
		return new IrFunction(fn.name, fn.arguments, fn.result, blocks, bindings, fn.inlineHint, fn.retention);
	}

	/** Replaces the call at `block.instructions[position]` by the callee's instructions; the result is substituted for the call's output. */
	function splice(block:IrBlock, position:Int, callee:IrFunction, substitutions:Map<Int, IrValue>, nextValue:Int):Int {
		var call = block.instructions[position],
			callOutput:IrValue = null,
			actuals:Array<IrValue> = [];
		switch call.value {
			case Call(out, _, arguments):
				callOutput = out;
				actuals = arguments;
			case MethodCall(out, object, _, arguments):
				callOutput = out;
				actuals = [object].concat(arguments);
			default:
				throw "Inliner expected a call";
		}
		var source = callee.blocks[0], values:Map<Int, IrValue> = [];
		for (argumentIndex in 0...callee.arguments.length)
			values.set(callee.arguments[argumentIndex].id, resolve(actuals[argumentIndex], substitutions));
		for (located in source.instructions) {
			var output = IrOperands.output(located.value);
			if (output != null)
				values.set(output.id, new IrValue(nextValue++, output.name, output.type));
		}
		var use = function(value:IrValue):IrValue {
			var mapped = values.get(value.id);
			if (mapped == null)
				throw "Inliner found an undefined callee value";
			return mapped;
		};
		var noBlocks = function(id:Int):Int {
			throw "A straight-line callee has no blocks to remap";
		};
		var copies:Array<Located<IrInstruction>> = [];
		for (located in source.instructions)
			copies.push(new Located(remap(located.value, use, noBlocks), located.provenance));
		var terminator = source.terminator;
		if (terminator == null)
			throw "A straight-line callee must end in a terminator";
		var returned:IrValue = switch terminator.value {
			case Return(value): use(value);
			default: throw "A straight-line callee must return";
		};
		if (callOutput.type == Void)
			copies.push(new Located(ConstVoid(callOutput), call.provenance));
		else
			substitutions.set(callOutput.id, returned);
		block.instructions.splice(position, 1);
		var at = position;
		for (copy in copies) {
			block.instructions.insert(at, copy);
			at++;
		}
		return nextValue;
	}

	static function resolve(value:IrValue, substitutions:Map<Int, IrValue>):IrValue {
		var current = value, steps = 0;
		while (substitutions.exists(current.id) && steps < 4096) {
			current = substitutions.get(current.id);
			steps++;
		}
		return current;
	}

	/** Rewrites every use of a spliced call's output to the value the callee returned. */
	function substitute(blocks:Array<IrBlock>, substitutions:Map<Int, IrValue>, bindings:Array<IrDebugBinding>):Array<IrDebugBinding> {
		var use = function(value:IrValue):IrValue return resolve(value, substitutions);
		var sameBlock = function(id:Int):Int return id;
		for (block in blocks) {
			for (position in 0...block.instructions.length) {
				var located = block.instructions[position];
				block.instructions[position] = new Located(remap(located.value, use, sameBlock), located.provenance);
			}
			var terminator = block.terminator;
			if (terminator != null)
				block.terminator = new Located(switch terminator.value {
					case Return(value): Return(use(value));
					case Throw(value): Throw(use(value));
					case Rethrow(value): Rethrow(use(value));
					case Jump(target): Jump(target);
					case Branch(condition, whenTrue, whenFalse): Branch(use(condition), whenTrue, whenFalse);
				}, terminator.provenance);
		}
		return [
			for (binding in bindings)
				{
					identity: binding.identity,
					name: binding.name,
					value: use(binding.value),
					path: binding.path,
					scopeStart: binding.scopeStart,
					scopeEnd: binding.scopeEnd
				}
		];
	}

	/**
	 * Replaces the call at `blocks[index].instructions[position]` by a copy of `callee`. The block keeps the
	 * instructions before the call and jumps into the copy; a fresh continuation block takes the instructions after the
	 * call and the original terminator, and merges the returned values with a phi.
	 */
	function expand(blocks:Array<IrBlock>, index:Int, position:Int, callee:IrFunction, nextValue:Int, nextBlock:Int):{nextValue:Int, nextBlock:Int} {
		var head = blocks[index],
			call = head.instructions[position],
			callOutput:IrValue = null,
			actuals:Array<IrValue> = [];
		switch call.value {
			case Call(out, _, arguments):
				callOutput = out;
				actuals = arguments;
			case MethodCall(out, object, _, arguments):
				callOutput = out;
				actuals = [object].concat(arguments);
			default:
				throw "Inliner expected a call";
		}
		var values:Map<Int, IrValue> = [], blockIds:Map<Int, Int> = [];
		for (argumentIndex in 0...callee.arguments.length)
			values.set(callee.arguments[argumentIndex].id, actuals[argumentIndex]);
		// Every definition first, so phis and back edges can refer to values defined later in block order.
		for (block in callee.blocks) {
			blockIds.set(block.id, nextBlock++);
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null) {
					values.set(output.id, new IrValue(nextValue++, output.name, output.type));
				}
			}
		}
		var continuation = new IrBlock(nextBlock++);
		var use = function(value:IrValue):IrValue {
			var mapped = values.get(value.id);
			if (mapped == null)
				throw "Inliner found an undefined callee value";
			return mapped;
		};
		var target = function(id:Int):Int {
			var mapped = blockIds.get(id);
			if (mapped == null)
				throw "Inliner found an unknown callee block";
			return mapped;
		};
		var cloned:Array<IrBlock> = [], returned:Array<IrPhiInput> = [];
		for (block in callee.blocks) {
			var copy = new IrBlock(target(block.id));
			for (located in block.instructions)
				copy.instructions.push(new Located(remap(located.value, use, target), located.provenance));
			var terminator = block.terminator;
			if (terminator == null)
				throw "Inliner found a callee block without a terminator";
			switch terminator.value {
				case Return(value):
					returned.push({block: copy.id, value: use(value)});
					copy.terminator = new Located(Jump(continuation.id), terminator.provenance);
				case Throw(value):
					copy.terminator = new Located(Throw(use(value)), terminator.provenance);
				case Rethrow(value):
					copy.terminator = new Located(Rethrow(use(value)), terminator.provenance);
				case Jump(destination):
					copy.terminator = new Located(Jump(target(destination)), terminator.provenance);
				case Branch(condition, whenTrue, whenFalse):
					copy.terminator = new Located(Branch(use(condition), target(whenTrue), target(whenFalse)), terminator.provenance);
			}
			cloned.push(copy);
		}
		// The continuation defines the call's output, then runs whatever followed the call.
		if (callOutput.type == Void)
			continuation.instructions.push(new Located(ConstVoid(callOutput), call.provenance));
		else
			continuation.instructions.push(new Located(Phi(callOutput, returned), call.provenance));
		for (rest in position + 1...head.instructions.length)
			continuation.instructions.push(head.instructions[rest]);
		continuation.terminator = head.terminator;
		head.instructions.resize(position);
		head.terminator = new Located(Jump(cloned[0].id), call.provenance);
		// Everything that used to leave the head now leaves the continuation, so successor phis name the new predecessor.
		var successors:Array<Int> = [];
		var continued = continuation.terminator;
		if (continued == null)
			throw "Inliner found a call site without a terminator";
		switch continued.value {
			case Jump(destination):
				successors.push(destination);
			case Branch(_, whenTrue, whenFalse):
				successors.push(whenTrue);
				successors.push(whenFalse);
			default:
		}
		for (located in continuation.instructions)
			switch located.value {
				case BeginTry(catchBlock, afterBlock):
					successors.push(catchBlock);
					successors.push(afterBlock);
				default:
			}
		for (candidate in blocks)
			if (successors.indexOf(candidate.id) >= 0)
				retargetPhis(candidate, head.id, continuation.id);
		var insertion:Array<IrBlock> = cloned.concat([continuation]);
		var at = index + 1;
		for (added in insertion) {
			blocks.insert(at, added);
			at++;
		}
		return {nextValue: nextValue, nextBlock: nextBlock};
	}

	static function retargetPhis(block:IrBlock, from:Int, to:Int):Void {
		for (position in 0...block.instructions.length) {
			var located = block.instructions[position];
			switch located.value {
				case Phi(output, inputs):
					var changed = false, updated:Array<IrPhiInput> = [];
					for (input in inputs) {
						if (input.block == from) {
							changed = true;
							updated.push({block: to, value: input.value});
						} else
							updated.push(input);
					}
					if (changed)
						block.instructions[position] = new Located(Phi(output, updated), located.provenance);
				default:
			}
		}
	}

	/** The instruction with every value (inputs and outputs alike) passed through `use` and every block id through `block`. */
	public static function remap(instruction:IrInstruction, use:IrValue->IrValue, block:Int->Int):IrInstruction {
		return switch instruction {
			case Phi(out, inputs): Phi(use(out), [for (input in inputs) {block: block(input.block), value: use(input.value)}]);
			case ConstVoid(out): ConstVoid(use(out));
			case ConstInt(out, value): ConstInt(use(out), value);
			case ConstFloat(out, value): ConstFloat(use(out), value);
			case ConstString(out, value): ConstString(use(out), value);
			case StaticDataAddress(out, bytes): StaticDataAddress(use(out), bytes);
			case PointerOffset(out, pointer, offset): PointerOffset(use(out), use(pointer), use(offset));
			case MemoryLoad(out, pointer, size, signed): MemoryLoad(use(out), use(pointer), size, signed);
			case MemoryStore(pointer, value, size): MemoryStore(use(pointer), use(value), size);
			case ConstBool(out, value): ConstBool(use(out), value);
			case ConstNull(out): ConstNull(use(out));
			case TypeValue(out, type): TypeValue(use(out), type);
			case ToDyn(out, value): ToDyn(use(out), use(value));
			case IntToFloat(out, value): IntToFloat(use(out), use(value));
			case IntToInt64(out, value): IntToInt64(use(out), use(value));
			case FloatToInt(out, value): FloatToInt(use(out), use(value));
			case SafeCast(out, value): SafeCast(use(out), use(value));
			// Callees with handlers are never cloned (see fits); these arise when a caller is rewritten in place.
			case BeginTry(catchBlock, afterBlock): BeginTry(block(catchBlock), block(afterBlock));
			case EndTry(catchBlock): EndTry(block(catchBlock));
			case Catch(out): Catch(use(out));
			case GlobalGet(out, name): GlobalGet(use(out), name);
			case GlobalSet(name, value): GlobalSet(name, use(value));
			case Add(out, a, b): Add(use(out), use(a), use(b));
			case Sub(out, a, b): Sub(use(out), use(a), use(b));
			case Mul(out, a, b): Mul(use(out), use(a), use(b));
			case Div(out, a, b): Div(use(out), use(a), use(b));
			case Mod(out, a, b): Mod(use(out), use(a), use(b));
			case BitAnd(out, a, b): BitAnd(use(out), use(a), use(b));
			case BitXor(out, a, b): BitXor(use(out), use(a), use(b));
			case BitOr(out, a, b): BitOr(use(out), use(a), use(b));
			case ShiftLeft(out, a, b): ShiftLeft(use(out), use(a), use(b));
			case ShiftRight(out, a, b): ShiftRight(use(out), use(a), use(b));
			case UnsignedShiftRight(out, a, b): UnsignedShiftRight(use(out), use(a), use(b));
			case Less(out, a, b): Less(use(out), use(a), use(b));
			case LessEqual(out, a, b): LessEqual(use(out), use(a), use(b));
			case Equal(out, a, b): Equal(use(out), use(a), use(b));
			case Call(out, name, arguments): Call(use(out), name, [for (argument in arguments) use(argument)]);
			case CNativeCall(out, name, arguments): CNativeCall(use(out), name, [for (argument in arguments) use(argument)]);
			case StaticClosure(out, name): StaticClosure(use(out), name);
			case InstanceClosure(out, name, receiver): InstanceClosure(use(out), name, use(receiver));
			case CallClosure(out, closure, arguments): CallClosure(use(out), use(closure), [for (argument in arguments) use(argument)]);
			case ToVirtual(out, value): ToVirtual(use(out), use(value));
			case MethodCall(out, object, name, arguments): MethodCall(use(out), use(object), name, [for (argument in arguments) use(argument)]);
			case NewObject(out, typeName): NewObject(use(out), typeName);
			case FieldGet(out, object, name): FieldGet(use(out), use(object), name);
			case FieldSet(object, name, value): FieldSet(use(object), name, use(value));
			case ArrayGet(out, array, index): ArrayGet(use(out), use(array), use(index));
			case ArraySet(array, index, value): ArraySet(use(array), use(index), use(value));
			case ArraySize(out, array): ArraySize(use(out), use(array));
			case IteratorNew(out, array): IteratorNew(use(out), use(array));
			case IteratorHasNext(out, iterator): IteratorHasNext(use(out), use(iterator));
			case IteratorNext(out, iterator): IteratorNext(use(out), use(iterator));
			case MakeEnum(out, typeName, constructor, arguments): MakeEnum(use(out), typeName, constructor, [for (argument in arguments) use(argument)]);
			case EnumIndex(out, value): EnumIndex(use(out), use(value));
			case EnumField(out, value, constructor, field): EnumField(use(out), use(value), constructor, field);
		};
	}
}
