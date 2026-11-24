package compiler.ir.passes.scalars;

import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import compiler.ir.passes.values.IrInlineValueLayout;
import compiler.ir.analysis.IrMethodResolution;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrProviders;
import compiler.ir.names.IrReceiverCheck;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrTypeTools;
import compiler.ir.model.IrValueId;
import compiler.ir.passes.values.IrValueLaneReference;
import compiler.ir.passes.values.IrValuePhiScalarization;
import compiler.ir.model.SourceProvenance;
import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.passes.values.IrInlineValueLayout.IrInlineValueSlot;

/** A direct call `rewriteCalls` replaces by one to a scalar clone, decided on the body before any row of it changes. */
private typedef ScalarCallPlan = {
	final block:Int;
	final row:Int;
	final check:Bool;
	final name:String;
	final pinned:Bool;
	final arguments:Array<IrValueId>;
}

/** The candidates `IrScalarArguments` chose, by name, which a session keeps (`IrScalarArguments.CHOICE`). */
private typedef ScalarArgumentChoice = {
	final candidates:Array<String>;
	final pinned:Array<String>;
	final freshOnly:Array<String>;
	final terminalOnly:Array<String>;
	final methodNames:Array<String>;
}

/**
 * Direct-call specialization for nonescaping value arguments; HashLink also supports scalar result slots. On IR bodies
 * (docs/design/IR_CORE_COLUMNS.md, migration): value joins are split first (`IrValuePhiScalarization`), then each candidate is
 * cloned with its value arguments expanded into slots, and direct calls are redirected to the clones in place.
 */
@:nullSafety(Strict)
class IrScalarArguments extends compiler.ir.pipeline.IrFunctionPass {
	/** The functions each function takes as closures. */
	@:processWide("a contribution memo's key, only ever read")
	public static final CLOSURE_NAMES =
		new compiler.ir.reuse.IrStageMemo.IrContributionKey<Array<String>>("closure-names");

	/**
	 * The choice of candidates, kept with what it read (`IrWalkRecord`): of each function that may be a candidate, all of it; of
	 * each other function, the names of the functions it takes as closures (but for the Wasm ABI, which reads none).
	 */
	@:processWide("a kept choice's key, only ever read")
	static final CHOICE = new compiler.ir.reuse.IrStageMemo
		.IrContributionKey<compiler.ir.reuse.IrWalkRecord<Array<String>, ScalarArgumentChoice>>("scalar-argument-choice");

	/** What the choice records of a function it reads whole (`CHOICE`): one that changed is chosen again. */
	@:processWide("a marker compared by identity, never changed")
	static final READ_WHOLE:Array<String> = [];

	public static inline final PREFIX = "$scalar-arguments:";

	// Summary bits: what the choice reads of a function.

	/** A function the scalar ABI permits whose signature names a class, which may then be a candidate. */
	static inline final SIGNATURE = 1;

	/** A function that takes closures, whose targets the choice keeps. */
	static inline final CLOSES = 2;

	/** The fact of the candidates as a whole: their names, what kind each is and their signatures, interned (`IrFacts.intern`). */
	static inline final CANDIDATES = 0;

	/** The fact of what a rewrite reads of the declarations, the value objects' layouts (`IrInlineValueLayout.declarationsFact`). */
	static inline final REWRITE = 1;

	/** The fact of the function a method call on an object of the key's class goes to, `class\u0001method`, interned. */
	static inline final METHOD = 2;

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
	final scratch:IrPassScratch;
	final argumentsOnly:Bool;
	final byName:Map<String, IrFunction>;
	final candidates:Map<String, IrBody> = [];
	final pinnedCandidates:Map<String, IrBody> = [];
	final freshOnly:Map<String, Bool> = [];
	final terminalOnly:Map<String, Bool> = [];
	final methodNames:Map<String, Bool> = [];
	var clones:Map<String, IrBody> = [];
	var pinnedClones:Map<String, IrBody> = [];
	var originals:Array<IrFunction> = [];

	/** The candidates' fact (`CANDIDATES`), set once they are chosen. */
	var candidatesPrint = 0;
	final lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>;
	final declarations:() -> Int;

	/** The version each candidate's clone is made from: its input's (`IrLineage.version`) as the stage starts. */
	final inputs:Map<String, Int> = [];

	/**
	 * Splits value joins and rewrites `program`'s functions and calls for the scalar ABI, on bodies, which this stage encodes when it
	 * is the pipeline's first over bodies. A function that changes becomes its edited body: owned by the next stage: edited in
	 * place, or a copy when a cache holds the body. With `argumentsOnly` (Wasm), no result slots and no receiver checks.
	 */
	public static function rewrite(program:IrProgram, argumentsOnly:Bool = false, ?scratch:IrPassScratch):Void {
		if (scratch == null)
			scratch = new IrPassScratch();
		// Call rewriting judges value arguments by their uses, which a value join hides.
		IrValuePhiScalarization.rewriteBodies(program, scratch);
		program.functions = compiler.ir.pipeline.IrFunctionStages.apply("scalar-arguments",
			new IrScalarArguments(program, argumentsOnly, scratch), program.functions);
	}

	/**
	 * The scalar ABI per function (`IrFunctionPass`) for the pipeline, after its value joins are split. The candidates are chosen
	 * over the whole program each run; the rewrite of a function reads them as one fact (`CANDIDATES`): a function that calls none
	 * of them keeps its form unread while they stay the same, and one that calls a candidate, or a method one implements, also
	 * reads the value layouts (`REWRITE`) and the target of each such method call (`METHOD`). The clones are added in `finish`,
	 * derived from their candidates' versions with the same reads.
	 */
	public function new(program:IrProgram, argumentsOnly:Bool, scratch:IrPassScratch,
			?lineage:compiler.ir.reuse.IrStageMemo.IrLineage) {
		this.program = program;
		this.lineage = lineage;
		this.argumentsOnly = argumentsOnly;
		this.scratch = scratch;
		objects = [for (object in program.objects) object.name => object];
		table = IrObjectTable.of(objects);
		layouts = new IrInlineValueLayout(table);
		resolution = IrMethodResolution.of(program);
		byName = [for (fn in program.functions) fn.name => fn];
		declarations = IrInlineValueLayout.declarationsFact(program.objects, lineage);
	}

	/**
	 * The candidates, chosen over the whole program from the functions the summaries name: those that may take the scalar ABI
	 * (`SIGNATURE`) and those that take closures (`CLOSES`). In a session the choice is kept (`CHOICE`) while the program's tables
	 * and those functions give it the same, and the clones are made only when a stage asks for one.
	 */
	override public function prepare(functions:Array<IrFunction>, summaries:Array<Int>,
			names:compiler.ir.pipeline.IrFunctionIndex):Void {
		originals = functions;
		var known = lineage;
		if (known == null) {
			choose(functions, summaries);
			return;
		}
		var memos = known.memos,
			given = [argumentsOnly ? "arguments only" : ""],
			last = memos.lastResult(CHOICE),
			memo = memos.contribution(CLOSURE_NAMES),
			kept = last == null ? null : last.holds(program, given, [], functions,
				(fn, closures) -> closures == READ_WHOLE || mayBeCandidate(fn) ? null : sameNames(closures,
				closureNames(fn)) ? closures : null);
		if (kept != null) {
			var choice = kept.result;
			for (name in choice.candidates)
				candidates.set(name, bodyNamed(name));
			for (name in choice.pinned)
				pinnedCandidates.set(name, bodyNamed(name));
			for (name in choice.freshOnly)
				freshOnly.set(name, true);
			for (name in choice.terminalOnly)
				terminalOnly.set(name, true);
			for (name in choice.methodNames)
				methodNames.set(name, true);
			if (known.checks)
				checkChoice(functions, summaries, choice);
			memos.keepResult(CHOICE, kept);
		} else {
			if (last != null)
				last.eachSummary((fn, closures) -> {
					var version = known.versionOf(fn);
					if (closures != READ_WHOLE && version != 0 && memo.get(version) == null)
						memo.keep(version, closures);
				});
			choose(functions, summaries);
			var read:Array<Null<Array<String>>> = [for (index in 0...functions.length) {
				var fn = functions[index];
				mayBeCandidate(fn) ? READ_WHOLE : argumentsOnly ? null : summaries[index] & CLOSES != 0
					? closureNames(fn) : [];
			}];
			memos.keepResult(CHOICE,
				new compiler.ir.reuse.IrWalkRecord(program, given, [], functions.copy(), read, chosen()));
		}
		candidatesPrint = printCandidates();
		for (name in candidates.keys())
			inputs.set(name, known.version(name));
		for (name in pinnedCandidates.keys())
			inputs.set(name, known.version(name));
	}

	/** The body of the function `name` of the program. */
	function bodyNamed(name:String):IrBody {
		var fn = byName.get(name);
		if (fn == null)
			throw new InternalError('Missing scalar ABI candidate "$name"');
		return fn.encodedBody(scratch.bodyBuilder);
	}

	/** What `choose` chose, as names. */
	function chosen():ScalarArgumentChoice {
		function sorted(keys:Iterator<String>):Array<String> {
			var names = [for (name in keys) name];
			names.sort(Reflect.compare);
			return names;
		}
		return {
			candidates: sorted(candidates.keys()),
			pinned: sorted(pinnedCandidates.keys()),
			freshOnly: sorted(freshOnly.keys()),
			terminalOnly: sorted(terminalOnly.keys()),
			methodNames: sorted(methodNames.keys())
		};
	}

	/** `--check-reuse`: choosing again gives the kept choice. */
	function checkChoice(functions:Array<IrFunction>, summaries:Array<Int>, kept:ScalarArgumentChoice):Void {
		var fresh = new IrScalarArguments(program, argumentsOnly, scratch, null);
		fresh.choose(functions, summaries);
		var now = fresh.chosen();
		if (!sameNames(now.candidates, kept.candidates) || !sameNames(now.pinned, kept.pinned)
			|| !sameNames(now.freshOnly, kept.freshOnly) || !sameNames(now.terminalOnly, kept.terminalOnly)
			|| !sameNames(now.methodNames, kept.methodNames))
			throw new InternalError('--check-reuse: the scalar ABI reused a choice of candidates that differs from choosing now');
	}

	static function sameNames(left:Array<String>, right:Array<String>):Bool
		return IrObjectTools.sameNames(left, right);

	/** Whether `fn` may be a candidate as the program's tables stand: a function the scalar ABI permits with a value in its signature. */
	function mayBeCandidate(fn:IrFunction):Bool
		return IrScalarAbiEligibility.permits(fn.kind, false) && signatureHasValue(fn);

	/** The candidates, chosen over the whole program; only functions with a value in their signature are read. */
	function choose(functions:Array<IrFunction>, summaries:Array<Int>):Void {
		// Typed closure signatures are an ABI decision, including forwarding closures.
		// Keep their scalar entry points available before IrScalarClosures rewrites
		// indirect calls; judging those calls against the boxed ABI here creates a
		// cycle that prevents allocation-free forwarding of value arguments/results.
		var closureTargets:Map<String, Bool> = [];
		if (!argumentsOnly)
			for (index in 0...functions.length)
				if (summaries[index] & CLOSES != 0)
					for (name in closureNames(functions[index]))
						closureTargets.set(name, true);
		// Methods that call out may snapshot only a fresh receiver: a field place can be changed by an alias
		// while the method runs, and must keep its original receiver ABI.
		for (position in 0...functions.length) {
			var fn = functions[position];
			if (summaries[position] & SIGNATURE == 0 || !mayBeCandidate(fn))
				continue;
			var body = fn.encodedBody(scratch.bodyBuilder);
			var resultType = IrTypeIds.type(body.result),
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
		var changed = true;
		while (changed) {
			changed = false;
			clones = [];
			pinnedClones = [];
			var allCandidates = candidates.copy();
			for (name => pinned in pinnedCandidates)
				allCandidates.set(name, pinned);
			for (fn in functions) {
				var body = candidates.get(fn.name);
				if (body != null) {
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
			}
			for (fn in functions) {
				var body = pinnedCandidates.get(fn.name);
				if (body != null) {
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
		}
	}

	override public function summarize(fn:IrFunction):Int {
		var flags = 0;
		if (IrScalarAbiEligibility.permits(fn.kind, false) && namesObject(fn))
			flags |= SIGNATURE;
		if (closureNames(fn).length > 0)
			flags |= CLOSES;
		return flags;
	}

	/** Whether `fn`'s signature names a class: only such a function can have a value in it, whichever classes are values. */
	static function namesObject(fn:IrFunction):Bool {
		inline function isObject(type:IrType):Bool
			return type.match(Obj(_));
		if (isObject(fn.result))
			return true;
		for (argument in fn.arguments)
			if (isObject(argument.type))
				return true;
		return false;
	}

	override public function fact(kind:Int, key:String):Int {
		switch kind {
			case CANDIDATES:
				return candidatesPrint;
			case REWRITE:
				return declarations();
			case _:
				var known = lineage, split = key.indexOf("\u0001");
				return known == null ? 0 : known.memos.facts.intern(resolveMethod(Obj(key.substr(0, split)),
					key.substr(split + 1)) ?? "");
		}
	}

	/** The number of the candidates' text in the session's facts (`CANDIDATES`), or 0 without a session. */
	function printCandidates():Int {
		var known = lineage;
		if (known == null)
			return 0;
		function sorted(keys:Iterator<String>):String {
			var names = [for (name in keys) name];
			names.sort(Reflect.compare);
			return names.join(",");
		}
		// A rewrite reads a candidate's arguments: their types and whether the first is the receiver.
		function signatures(bodies:Map<String, IrBody>):String {
			var names = [for (name in bodies.keys()) name];
			names.sort(Reflect.compare);
			return [for (name in names) {
				var body = bodies.get(name);
				body == null ? "" : [
					for (index in 0...body.argumentCount())
						body.valueName(body.argument(index)) + ":" + IrTypeIdentity.text(argumentType(body, index))
				].join(",");
			}].join(";");
		}
		return known.memos.facts.intern([
			sorted(candidates.keys()), sorted(pinnedCandidates.keys()), sorted(freshOnly.keys()),
			sorted(terminalOnly.keys()),
			sorted(methodNames.keys()), signatures(candidates), signatures(pinnedCandidates)
		].join(";"));
	}

	override public function transform(fn:IrFunction, summary:Int, reader:compiler.ir.reuse.IrFactReader):IrFunction {
		var body = fn.encodedBody(scratch.bodyBuilder);
		// The calls a function makes go to a candidate or not by the candidates; a method call's target by the classes
		// (`METHOD`), and a rewrite's slots by the value layouts (`REWRITE`).
		reader.read(CANDIDATES, "");
		if (!candidates.keys().hasNext() && !pinnedCandidates.keys().hasNext())
			return fn;
		if (readCandidateCalls(body, reader))
			reader.read(REWRITE, "");
		return rewriteFunction(fn, body);
	}

	/**
	 * Reads, through `reader`, the target of each call of `body` to a method a candidate implements (`methodNames`); returns whether
	 * `body` calls a candidate or such a method at all, directly or through a closure, which only then may a rewrite change.
	 */
	function readCandidateCalls(body:IrBody, reader:compiler.ir.reuse.IrFactReader):Bool {
		var calls = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.MethodCall if (methodNames.exists(body.symbol(row).name)):
						switch body.valueType(body.operand(row, 0)) {
							case Obj(name):
								reader.read(METHOD, name + "\u0001" + body.symbol(row).name);
							default:
						}
						calls = true;
					case IrOpcode.Call, IrOpcode.StaticClosure, IrOpcode.InstanceClosure:
						var name = body.symbol(row).name;
						if (candidates.exists(name) || pinnedCandidates.exists(name))
							calls = true;
					default:
				}
				row = body.nextRow(row);
			}
		}
		return calls;
	}

	override public function request(kind:Int, type:IrType, name:Null<String>):Void
		throw new InternalError("The scalar ABI asks for no helper");

	/** The rewritten functions, then the candidates' clones and the receiver-preserving ones a call selects. */
	override public function finish(rewritten:Array<IrFunction>):Array<IrFunction> {
		if (!candidates.keys().hasNext() && !pinnedCandidates.keys().hasNext())
			return rewritten;
		rewritten = rewritten.copy();
		// Every candidate left has its clone.
		for (fn in originals)
			if (candidates.exists(fn.name))
				rewritten.push(publish(fn.name, false));
		if (!pinnedCandidates.keys().hasNext())
			return rewritten;
		// Receiver-preserving variants are only useful when a rewritten call selects one.
		// Keep their transitive dependencies, but do not publish every possible variant into
		// the program: an unused variant still consumes module and JIT metadata.
		var pinnedByName:Map<String, String> = [],
			needed:Map<String, Bool> = [],
			pending:Array<String> = [];
		for (name in pinnedCandidates.keys())
			pinnedByName.set(cloneName(name, true), name);
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
			discover(fn.encodedBody(scratch.bodyBuilder));
		while (pending.length > 0) {
			var name = pending.pop();
			if (name == null)
				break;
			var source = pinnedByName.get(name);
			if (source == null)
				throw new InternalError('Missing receiver-preserving clone "$name"');
			discover(cloneOf(source, true));
		}
		for (fn in originals)
			if (pinnedCandidates.exists(fn.name) && needed.exists(cloneName(fn.name, true)))
				rewritten.push(publish(fn.name, true));
		return rewritten;
	}

	/** The functions `fn` takes as closures, read once per version in a session (`IrStageMemos.closureNames`). */
	function closureNames(fn:IrFunction):Array<String> {
		var known = lineage, version = known == null ? 0 : known.versionOf(fn);
		if (known == null || version == 0)
			return readClosureNames(fn.encodedBody(scratch.bodyBuilder));
		var memo = known.memos.contribution(CLOSURE_NAMES), names = memo.get(version);
		if (names == null) {
			names = readClosureNames(fn.encodedBody(scratch.bodyBuilder));
			memo.keep(version, names);
		} else if (known.checks && names.join(",") != readClosureNames(fn.encodedBody(scratch.bodyBuilder)).join(","))
			throw new InternalError('--check-reuse: the closures reused for ${fn.name} differ from its body');
		return names;
	}

	static function readClosureNames(body:IrBody):Array<String> {
		var names:Array<String> = [];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.StaticClosure, IrOpcode.InstanceClosure:
						var name = body.symbol(row).name;
						if (names.indexOf(name) < 0)
							names.push(name);
					default:
				}
				row = body.nextRow(row);
			}
		}
		return names;
	}

	/** Whether `fn`'s result or an argument is a value: only such a function can be a candidate. */
	function signatureHasValue(fn:IrFunction):Bool {
		if (isValue(fn.result))
			return true;
		for (argument in fn.arguments)
			if (isValue(argument.type))
				return true;
		return false;
	}

	/** `body`'s clone for the scalar ABI, its calls rewritten, its value joins split and its value allocations replaced. */
	function specialize(body:IrBody, preserveReceiver:Bool):IrBody {
		var specialized = clone(body, preserveReceiver);
		rewriteCalls(specialized);
		// Scalar call rewriting can introduce value constructions into a join. Split those joins before
		// judging whether the specialized callee can keep its value arguments and result in registers.
		specialized = IrValuePhiScalarization.runBody(specialized, objects, table, layouts, null, scratch);
		IrScalarReplacement.runBody(specialized, table, scratch, true, true);
		return specialized;
	}

	/**
	 * Whether `specialized`, the clone of `body`, still makes one of the value arguments from `first` on, or its value result, as
	 * an object that is not a register place, or receives a value result from a call.
	 */
	function keepsValue(body:IrBody, specialized:IrBody, first:Int):Bool {
		var places = new IrScalarValuePlaces(specialized, name -> objects.get(name)),
			resultType = IrTypeIds.type(body.result),
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

	/** The name of the clone of candidate `name`, the receiver-preserving one when `pinned`. */
	static function cloneName(name:String, pinned:Bool):String
		return PREFIX + (pinned ? "$receiver:" : "") + name;

	/** The clone of candidate `name`, made the first time it is asked for. */
	function cloneOf(name:String, pinned:Bool):IrBody {
		var made = pinned ? pinnedClones : clones, known = made.get(name);
		if (known == null) {
			var body = (pinned ? pinnedCandidates : candidates).get(name);
			if (body == null)
				throw new InternalError('Missing scalar ABI candidate "$name"');
			known = specialize(body, pinned);
			made.set(name, known);
		}
		return known;
	}

	/**
	 * The clone of the candidate `name`, derived (`IrFunctionStages.derived`): in a session last build's while the candidate's
	 * version and what the clone read hold, and made only otherwise.
	 */
	function publish(name:String, pinned:Bool):IrFunction {
		var known = lineage, candidate = byName.get(name);
		if (candidate == null)
			throw new InternalError('Missing scalar ABI candidate "$name"');
		var source = candidate.encodedBody(scratch.bodyBuilder);
		return compiler.ir.pipeline.IrFunctionStages.derived("scalar-arguments", cloneName(name, pinned), this,
			inputs.get(name) ?? 0, known, known != null && known.checks, scratch.bodyBuilder, reader -> {
				reader.read(CANDIDATES, "");
				readCandidateCalls(source, reader);
				reader.read(REWRITE, "");
				IrFunction.ofOwnedBody(cloneOf(name, pinned));
			});
	}

	/** `fn`, whose body is `body`, with its direct calls to candidates redirected: `fn` itself when it has none. */
	function rewriteFunction(fn:IrFunction, body:IrBody):IrFunction {
		var plans = planCalls(body);
		if (plans.length == 0)
			return fn;
		var edited = body.forEditing(scratch.bodyBuilder);
		if (edited != body)
			plans = planCalls(edited);
		applyCalls(edited, plans);
		return IrFunction.ofOwnedBody(edited);
	}

	/** Redirects the direct calls of `body`, which this stage owns, in place. */
	function rewriteCalls(body:IrBody):Void {
		var plans = planCalls(body);
		if (plans.length > 0)
			applyCalls(body, plans);
	}

	static function isValueIn(type:IrType, objects:Map<String, IrObject>):Bool
		return switch type {
			case Obj(name):
				var object = objects.get(name);
				object != null && object.isValue;
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
		var aliases = aliasesOf(body, arg), valueResult = isValue(IrTypeIds.type(body.result));
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
						case IrOpcode.Call:
							var target = candidates.get(body.symbol(row).name);
							if (target == null)
								return false;
							for (index in 0...body.operandCount(row))
								if (aliases.exists(body.operand(row, index)) && !isValue(argumentType(target, index)))
									return false;
						case IrOpcode.MethodCall if (methodNames.exists(body.symbol(row).name)):
							var name = resolveMethod(body.valueType(body.operand(row, 0)), body.symbol(row).name);
							var target = name == null ? null : candidates.get(name);
							if (target == null)
								return false;
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
	 * return stores through.
	 */
	function clone(source:IrBody, preserveReceiver:Bool):IrBody {
		var builder = scratch.bodyBuilder, next = source.valueLimit();
		builder.startFrom(source);
		builder.clearArguments();
		var origin = SourceProvenance.generated("scalar-argument");
		function define(name:String, type:IrType):IrValueId {
			var id = IrValueId.of(next++);
			builder.defineValue(id, name, IrTypeIds.id(type));
			return id;
		}
		var resultType = IrTypeIds.type(source.result),
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
		return builder.finishAs(PREFIX + (preserveReceiver ? "$receiver:" : "") + source.name, ScalarArguments,
			returnSlots.length > 0 ? IrTypeIds.id(Void) : source.result, source.inlineHint, Reachable);
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
			return null;
		var pinned = pinnedCandidates.exists(name)
			&& (!candidates.exists(name)
			|| freshOnly.exists(name)
			&& !terminalFresh
			&& arguments.length > 0
			&& (terminalOnly.exists(name) || !freshForCandidate(body, arguments[0], name)));
		return {
			block: block,
			row: row,
			check: check,
			name: name,
			pinned: pinned,
			arguments: arguments
		};
	}

	/**
	 * Replaces each planned call of `body` by the call of its clone: value arguments read field by field, a reference per result
	 * slot, and the value result made again from them.
	 */
	function applyCalls(body:IrBody, plans:Array<ScalarCallPlan>):Void {
		inline function fresh(name:String, type:IrType):IrValueId
			return body.newValue(name, body.typeId(type));
		for (plan in plans) {
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
				emit(IrOpcode.Call, checked, IrReceiverCheck.symbol());
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
			var targetResult = IrTypeIds.type(target.result),
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
