package compiler.ir.passes.nullability;

import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.IrValueId;
import compiler.ir.model.TypeKey;
import compiler.ir.passes.scalars.IrScalarArguments;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrStageFacts;
import compiler.ir.reuse.IrStageMemo.IrStageMemos;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.model.Ir;
import compiler.ir.model.IrFunction;

/**
 * Keep nonescaping nullable scalars in presence/payload SSA form across control-flow joins. Runs on bodies
 * (docs/design/IR_CORE_COLUMNS.md), per function (`IrFunctionPass`): each function is read as its body, and one that changes is
 * rebuilt into a body this pass owns, so a function nothing changes stays the same object.
 *
 * The candidates, functions whose nullable scalar arguments every caller can pass split, are chosen over the whole program. The
 * rewrite of a function reads, for each function it calls, whether it is a candidate and with which arguments (`CANDIDATE`), and
 * asks for the require and equality helpers it calls. The candidates' specializations and the helpers are made in `finish`
 * (`IrFunctionStages.derived`), so a session reuses them too.
 */
@:nullSafety(Strict)
class IrNullableScalarFlow extends IrFunctionPass {
	public static inline final PREFIX = "$nullable-scalar:require:";
	public static inline final EQUAL_PREFIX = "$nullable-scalar:equal:";
	public static inline final CALL_PREFIX = "$nullable-scalar:arguments:";

	static inline final STAGE = "nullable-scalar-flow";

	/**
	 * The candidates the stage chose, by name, and the helpers their analysis called for, kept with the functions that may be a
	 * candidate (`IrWalkRecord`).
	 */
	@:processWide("a kept choice's key, only ever read")
	static final CHOICE = new compiler.ir.reuse.IrStageMemo.IrContributionKey<compiler.ir.reuse.IrWalkRecord<Bool, {
		candidates:Array<String>,
		helpers:Map<String, IrType>
	}>>("nullable-scalar-choice");

	/** The summary of a function with a nullable scalar argument and another result, which may be a candidate. */
	static inline final MAY_BE_CANDIDATE = 1;

	/** The fact of a function by name: 0 when it is not a candidate, else its arity and nullable scalar arguments. */
	public static inline final CANDIDATE = 0;

	// The helper kinds (`request`).
	public static inline final REQUIRE = 0;
	public static inline final EQUAL = 1;

	final program:IrProgram;
	final scratch:IrPassScratch;
	final stageMemos:Null<IrStageMemos>;
	final checks:Bool;
	final candidates:Map<String, IrFunction> = [];
	final helpers:Map<String, IrType> = [];
	var originals:Array<IrFunction> = [];
	var flow:Null<IrBodyNullableScalars> = null;

	/** By candidate, the version of the function its specialization is made from. */
	final inputs:Map<String, Int> = [];

	public function new(program:IrProgram, scratch:IrPassScratch, stageMemos:Null<IrStageMemos>, checks:Bool) {
		this.program = program;
		this.scratch = scratch;
		this.stageMemos = stageMemos;
		this.checks = checks;
	}

	/**
	 * Rewrites `program`'s functions, reading them as bodies, without a memo: a function that changes becomes its edited body,
	 * owned by the next stage (`IrFunction.ofOwnedBody`).
	 */
	public static function rewrite(program:IrProgram, ?scratch:IrPassScratch):Void {
		program.functions = IrFunctionStages.apply(STAGE,
			new IrNullableScalarFlow(program, scratch == null ? new IrPassScratch() : scratch, null, false),
			program.functions);
	}

	function analysis():IrBodyNullableScalars {
		var known = flow;
		if (known == null)
			throw new InternalError("The nullable scalar flow is not prepared");
		return known;
	}

	override public function summarize(fn:IrFunction):Int {
		if (inner(fn.result) != null || isSpecialization(fn.name))
			return 0;
		for (arg in fn.arguments)
			if (inner(arg.type) != null)
				return MAY_BE_CANDIDATE;
		return 0;
	}

	/**
	 * The candidates, from the functions whose summaries say they may be one: those every caller can pass split, read from their
	 * bodies. In a session the choice is kept (`CHOICE`) while those functions are the same.
	 */
	override public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {
		originals = functions;
		var known = stageMemos,
			last = known == null ? null : known.lastResult(CHOICE),
			// The choice reads nothing of the program but these functions, so a changed one is chosen again.
			kept = last == null ? null : last.holds(program, [], [], functions, (_, _) -> null);
		var made = new IrBodyNullableScalars(scratch, candidates, helpers);
		flow = made;
		if (kept != null) {
			var choice = kept.result, chosen = [for (name in choice.candidates) name => true];
			for (index in 0...functions.length)
				if (summaries[index] & MAY_BE_CANDIDATE != 0 && chosen.exists(functions[index].name))
					candidates.set(functions[index].name, functions[index]);
			for (name => type in choice.helpers)
				helpers.set(name, type);
			if (checks) {
				var now:Map<String, IrType> = [];
				if (!sameNames(choose(functions, summaries, new Map(), now), candidates) || !sameNames(now, helpers))
					throw new InternalError('--check-reuse: the nullable scalar flow reused a choice that differs from choosing now');
			}
		} else
			choose(functions, summaries, candidates, helpers);
		if (known != null) {
			if (kept == null)
				kept = new compiler.ir.reuse.IrWalkRecord(program, [], [], functions.copy(),
					[for (summary in summaries) summary & MAY_BE_CANDIDATE != 0 ? true : null],
					{candidates: [for (name in candidates.keys()) name], helpers: helpers.copy()});
			known.keepResult(CHOICE, kept);
			for (name => fn in candidates)
				inputs.set(name, fn.version);
		}
	}

	/**
	 * Chooses into `chosen` the candidates among `functions` (by their summaries), which it returns; the helpers their analysis
	 * calls for go to `needs`.
	 */
	function choose(functions:Array<IrFunction>, summaries:Array<Int>, chosen:Map<String, IrFunction>,
			needs:Map<String, IrType>):Map<String, IrFunction> {
		for (index in 0...functions.length)
			if (summaries[index] & MAY_BE_CANDIDATE != 0)
				chosen.set(functions[index].name, functions[index]);
		var analysis = new IrBodyNullableScalars(scratch, chosen, needs), builder = scratch.bodyBuilder, changed = true;
		while (changed) {
			changed = false;
			for (fn in [for (fn in chosen) fn])
				if (!analysis.analyze(fn.encodedBody(builder), true)) {
					chosen.remove(fn.name);
					changed = true;
				}
		}
		return chosen;
	}

	static function sameNames<T>(left:Map<String, T>, right:Map<String, T>):Bool {
		for (name in left.keys())
			if (!right.exists(name))
				return false;
		for (name in right.keys())
			if (!left.exists(name))
				return false;
		return true;
	}

	override public function fact(kind:Int, key:String):Int {
		var called = candidates.get(key);
		if (called == null)
			return 0;
		var count = called.arguments.length;
		if (count > 22)
			return IrStageFacts.UNKNOWN;
		var shape = 1 | count << 1;
		for (index in 0...count)
			if (inner(called.arguments[index].type) != null)
				shape |= 1 << (index + 9);
		return shape;
	}

	override public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		var flow = analysis();
		flow.reader = reader;
		var result = rewritten(flow, fn, scratch.bodyBuilder, false);
		flow.reader = null;
		return result;
	}

	override public function request(kind:Int, type:IrType, name:Null<String>):Void
		helpers.set(helperName(kind, type), type);

	public static function helperName(kind:Int, type:IrType):String
		return (kind == EQUAL ? EQUAL_PREFIX : PREFIX) + IrTypeIdentity.text(type);

	override public function finish(functions:Array<IrFunction>):Array<IrFunction> {
		var result = functions.copy(), flow = analysis(), builder = scratch.bodyBuilder;
		for (fn in originals)
			if (candidates.exists(fn.name)) {
				var input = inputs.get(fn.name) ?? 0;
				result.push(IrFunctionStages.derived(STAGE, specializationName(fn.name), this, input, stageMemos,
					builder, reader -> {
						flow.reader = reader;
						var made = rewritten(flow, fn, builder, true);
						flow.reader = null;
						made;
					}));
			}
		var names = [for (name in helpers.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var type = helpers.get(name);
			if (type != null)
				result.push(IrFunctionStages.derived(STAGE, name, this, IrFunctionStages.FROM_NAME, stageMemos, builder,
					_ -> helper(name, type)));
		}
		return result;
	}

	/** The require or equality helper `name` for the scalar `type`. */
	static function helper(name:String, type:IrType):IrFunction {
		var builder = new IrBuilder(),
			present = builder.argument("present", Bool),
			payload = builder.argument("payload", type);
		if (StringTools.startsWith(name, EQUAL_PREFIX)) {
			var otherPresent = builder.argument("other-present", Bool),
				otherPayload = builder.argument("other-payload", type),
				same = builder.createBlock(),
				different = builder.createBlock(),
				absent = builder.createBlock(),
				compare = builder.createBlock();
			builder.branch(builder.equal(present, otherPresent), same, different);
			builder.select(different);
			builder.returnValue(builder.constBool(false));
			builder.select(same);
			builder.branch(present, compare, absent);
			builder.select(absent);
			builder.returnValue(builder.constBool(true));
			builder.select(compare);
			builder.returnValue(builder.equal(payload, otherPayload));
			return new IrFunction(name, builder.arguments, Bool, builder.blocks,
				Provider(TypeKey.of(type),
				ProviderOperations.detailed(ProviderOperation.NullableScalarHelper, "equal")));
		}
		var yes = builder.createBlock(), no = builder.createBlock();
		builder.branch(present, yes, no);
		builder.select(yes);
		builder.returnValue(payload);
		builder.select(no);
		builder.terminate(Throw(builder.toDyn(builder.constString("Null access"))));
		return new IrFunction(name, builder.arguments, type, builder.blocks,
			Provider(TypeKey.of(type), ProviderOperations.detailed(ProviderOperation.NullableScalarHelper, "require")));
	}

	/** `fn` with its nullable scalars split, or its specialization (`clone`); `fn` itself when nothing changes. */
	static function rewritten(flow:IrBodyNullableScalars, fn:IrFunction, builder:IrBodyBuilder, clone:Bool):IrFunction {
		var body = fn.encodedBody(builder);
		if (!flow.analyze(body, clone) || !flow.splits())
			return fn;
		var built = flow.build(body, builder, clone);
		return IrFunction.ofOwnedBody(built);
	}

	/** Nullable argument expansion preserves an existing scalar result/stack-reference ABI. */
	public static function specializationName(name:String):String {
		var scalar = IrScalarArguments.PREFIX;
		return StringTools.startsWith(name, scalar)
			? scalar + CALL_PREFIX + name.substr(scalar.length) : CALL_PREFIX + name;
	}

	static function isSpecialization(name:String):Bool
		return StringTools.startsWith(name, CALL_PREFIX)
			|| StringTools.startsWith(name, IrScalarArguments.PREFIX + CALL_PREFIX);

	public static function inner(type:IrType):Null<IrType>
		return switch type {
			case Nullable(I32): I32;
			case Nullable(I64): I64;
			case Nullable(F32): F32;
			case Nullable(F64): F64;
			case Nullable(Bool): Bool;
			default: null;
		};

}

/**
 * The analysis and the rewrite of `IrNullableScalarFlow` on one body at a time, its tables by value id kept between bodies.
 * A candidate is a nullable scalar whose every use can read a presence flag and a payload instead: a null constant, a scalar
 * boxed to its nullable type, a phi of candidates, and, in a specialization, an argument.
 */
@:nullSafety(Strict)
class IrBodyNullableScalars {
	static inline final CANDIDATE = 1;
	static inline final NULL = 2;

	final scratch:IrPassScratch;
	final functions:Map<String, IrFunction>;
	final checks:Map<String, IrType>;

	/** The reader of the rewrite being made, through which it reads the candidates and asks for helpers; null to only analyze. */
	public var reader:Null<IrFactReader> = null;

	/** By value id: CANDIDATE while it is one, NULL when a null constant defines it. */
	var states:Array<Int>;

	/** The candidates in the order they were found, rejected ones included. */
	var order:Array<Int>;

	/** By candidate value id, its presence flag's id (the payload's is the next); by payload id, the value that replaces it or -1. */
	var parts:Array<Int>;

	var substitutions:Array<Int>;
	var changed = false;

	public function new(scratch:IrPassScratch, functions:Map<String, IrFunction>, checks:Map<String, IrType>) {
		this.scratch = scratch;
		this.functions = functions;
		this.checks = checks;
		states = scratch.firstInts;
		order = scratch.pendingIds;
		parts = scratch.secondInts;
		substitutions = scratch.thirdInts;
	}

	inline function isCandidate(value:IrValueId):Bool
		return (states[value] & CANDIDATE) != 0;

	inline function isNull(value:IrValueId):Bool
		return (states[value] & NULL) != 0;

	function reject(value:IrValueId):Void
		if (isCandidate(value)) {
			states[value] &= ~CANDIDATE;
			changed = true;
		}

	function found(value:IrValueId, state:Int):Void {
		states[value] = state;
		order.push(value);
	}

	/**
	 * Finds the candidates of `body` (its nullable arguments too for a specialization, `clone`) and rejects those with a use
	 * that needs the box; whether the function stays eligible, which only a specialization can fail.
	 */
	public function analyze(body:IrBody, clone:Bool):Bool {
		IrPassScratch.filledInts(states, body.valueLimit(), 0);
		order.resize(0);
		if (clone)
			for (index in 0...body.argumentCount()) {
				var argument = body.argument(index);
				if (IrNullableScalarFlow.inner(body.valueType(argument)) != null)
					found(argument, CANDIDATE);
			}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var out = body.output(row);
				if (out.exists()) {
					var type = IrNullableScalarFlow.inner(body.valueType(out));
					if (type != null)
						switch body.opcode(row) {
							case IrOpcode.ConstNull:
								found(out, CANDIDATE | NULL);
							case IrOpcode.ToDyn if (Type.enumEq(body.valueType(body.operand(row, 0)), type)):
								found(out, CANDIDATE);
							case IrOpcode.Phi:
								found(out, CANDIDATE);
							default:
						}
				}
				row = body.nextRow(row);
			}
		}
		if (order.length == 0)
			return true;
		// All uses of a component value must be expressible without reconstructing its box.
		// Remove whole connected phi groups when any boundary escapes or has an unsupported operation.
		changed = true;
		while (changed) {
			changed = false;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					rejectUses(body, row);
					row = body.nextRow(row);
				}
			}
		}
		if (clone)
			for (index in 0...body.argumentCount()) {
				var argument = body.argument(index);
				if (IrNullableScalarFlow.inner(body.valueType(argument)) != null && !isCandidate(argument))
					return false;
			}
		return true;
	}

	/** Whether the last analysis left a candidate, so the body changes. */
	public function splits():Bool {
		for (value in order)
			if (isCandidate(IrValueId.of(value)))
				return true;
		return false;
	}

	/** The candidate function a call row targets, when it passes as many arguments as that function takes, or null. */
	function calledCandidate(body:IrBody, row:Int):Null<IrFunction> {
		var called = candidate(body.symbol(row).name);
		return called != null && called.arguments.length == body.operandCount(row) ? called : null;
	}

	/** The candidate `name`, read as a fact while a function is rewritten. */
	function candidate(name:String):Null<IrFunction> {
		var current = reader;
		if (current != null)
			current.read(IrNullableScalarFlow.CANDIDATE, name);
		return functions.get(name);
	}

	/** Asks for the helper of `kind`, named `name`, for the scalar `type`. */
	function need(kind:Int, name:String, type:IrType):Void {
		var current = reader;
		if (current != null)
			current.request(kind, type);
		else
			checks.set(name, type);
	}

	function isEqualityOfNullables(body:IrBody, row:Int):Bool {
		if (body.symbol(row).name != "__dynamic_equal" || body.operandCount(row) != 2)
			return false;
		var left = body.valueType(body.operand(row, 0));
		return Type.enumEq(left, body.valueType(body.operand(row, 1))) && IrNullableScalarFlow.inner(left) != null;
	}

	function rejectUses(body:IrBody, row:Int):Void {
		var count = body.operandCount(row);
		switch body.opcode(row) {
			case IrOpcode.Phi:
				var out = body.output(row), eligible = isCandidate(out);
				for (index in 0...count)
					if (!isCandidate(body.operand(row, index)))
						eligible = false;
				if (!eligible) {
					reject(out);
					for (index in 0...count)
						reject(body.operand(row, index));
				}
			case IrOpcode.Call if (candidate(body.symbol(row).name) != null):
				var called = calledCandidate(body, row), eligible = called != null;
				if (called != null)
					for (index in 0...count)
						if (IrNullableScalarFlow.inner(called.arguments[index].type) != null
							&& !isCandidate(body.operand(row, index)))
							eligible = false;
				if (!eligible)
					for (index in 0...count)
						reject(body.operand(row, index));
			case IrOpcode.Call if (isEqualityOfNullables(body, row)):
				if (!isCandidate(body.operand(row, 0)) || !isCandidate(body.operand(row, 1))) {
					reject(body.operand(row, 0));
					reject(body.operand(row, 1));
				}
			case IrOpcode.Return, IrOpcode.Throw, IrOpcode.Rethrow, IrOpcode.Branch, IrOpcode.Switch:
				if (count > 0)
					reject(body.operand(row, 0));
			case IrOpcode.Unreachable, IrOpcode.Jump:
			case opcode:
				for (index in 0...count) {
					var value = body.operand(row, index);
					if (isCandidate(value) && !allowedUse(body, opcode, row, index, value))
						reject(value);
				}
		}
	}

	function allowedUse(body:IrBody, opcode:IrOpcode, row:Int, index:Int, value:IrValueId):Bool
		return switch opcode {
			case IrOpcode.SafeCast:
				var inner = IrNullableScalarFlow.inner(body.valueType(value));
				index == 0 && inner != null && Type.enumEq(body.valueType(body.output(row)), inner);
			case IrOpcode.Equal:
				var left = body.operand(row, 0), right = body.operand(row, 1);
				(left == value && isNull(right)) || (right == value && isNull(left));
			default:
				false;
		};

	/** The scalar that `value`, a candidate, holds when present. */
	static function scalarOf(body:IrBody, value:IrValueId):IrType {
		var scalar = IrNullableScalarFlow.inner(body.valueType(value));
		if (scalar == null)
			throw new InternalError("A nullable scalar candidate holds no scalar");
		return scalar;
	}

	inline function present(value:IrValueId):IrValueId
		return IrValueId.of(parts[value]);

	/** The payload of candidate `value`, or what replaces it. */
	function payload(value:IrValueId):IrValueId {
		var id = parts[value] + 1, replacement = id < substitutions.length ? substitutions[id] : -1;
		return IrValueId.of(replacement >= 0 ? replacement : id);
	}

	/**
	 * The body of the last analysis with its candidates split, made with `builder`: for the function itself, or for its
	 * specialization (`clone`), which takes each nullable argument as a flag and a payload under its own name.
	 */
	public function build(body:IrBody, builder:IrBodyBuilder, clone:Bool):IrBody {
		var next = body.valueLimit();
		builder.startFrom(body);
		var boolType = body.typeId(Bool);
		IrPassScratch.filledInts(parts, body.valueLimit(), -1);
		for (value in order) {
			var id = IrValueId.of(value);
			if (!isCandidate(id))
				continue;
			parts[value] = next;
			builder.defineValue(IrValueId.of(next++), "$nullable-present", boolType);
			builder.defineValue(IrValueId.of(next++), "$nullable-payload",
				body.typeId(scalarOf(body, id)));
		}
		IrPassScratch.filledInts(substitutions, next, -1);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.ToDyn && isCandidate(body.output(row)))
					substitutions[parts[body.output(row)] + 1] = body.operand(row, 0);
				row = body.nextRow(row);
			}
		}
		if (clone) {
			builder.clearArguments();
			for (index in 0...body.argumentCount()) {
				var argument = body.argument(index);
				if (isCandidate(argument)) {
					builder.addArgument(present(argument));
					builder.addArgument(payload(argument));
				} else
					builder.addArgument(argument);
			}
		}
		for (block in 0...body.blockCount()) {
			builder.beginBlock(body.blockId(block));
			var row = body.firstRow(block);
			while (row >= 0) {
				next = buildRow(body, builder, row, next, boolType);
				row = body.nextRow(row);
			}
		}
		for (index in 0...body.bindingCount()) {
			var value = body.bindingValue(index);
			if (!isCandidate(value))
				builder.copyBinding(body, index, value);
		}
		var kind = clone ? (switch body.kind {
			case ScalarArguments: GeneratedHelper;
			default: NullableScalarArguments;
		}) : body.kind;
		return builder.finishAs(clone ? IrNullableScalarFlow.specializationName(body.name) : body.name, kind,
			body.result, body.inlineHint, clone ? IrRetention.Reachable : body.retention);
	}

	/** Appends `row` rewritten, or as it is; the next new value's id after it. */
	function buildRow(body:IrBody, builder:IrBodyBuilder, row:Int, next:Int, boolType:Int):Int {
		var where = body.provenance(row), out = body.output(row);
		switch body.opcode(row) {
			case IrOpcode.Call if (candidate(body.symbol(row).name) != null):
				var called = calledCandidate(body, row), name = body.symbol(row).name;
				if (called == null || !expands(body, row, called)) {
					builder.copyRow(body, row);
					return next;
				}
				for (index in 0...body.operandCount(row)) {
					var argument = body.operand(row, index);
					if (IrNullableScalarFlow.inner(called.arguments[index].type) != null) {
						builder.operandId(present(argument));
						builder.operandId(payload(argument));
					} else
						builder.operandId(argument);
				}
				builder.row(IrOpcode.Call, out, IrSymbol.of(IrNullableScalarFlow.specializationName(name)).id, where);
			case IrOpcode.Call if (isEqualityOfNullables(body, row) && isCandidate(body.operand(row, 0))
				&& isCandidate(body.operand(row, 1))):
				var left = body.operand(row, 0),
					right = body.operand(row, 1),
					type = scalarOf(body, left),
					name = IrNullableScalarFlow.helperName(IrNullableScalarFlow.EQUAL, type);
				need(IrNullableScalarFlow.EQUAL, name, type);
				builder.operandId(present(left));
				builder.operandId(payload(left));
				builder.operandId(present(right));
				builder.operandId(payload(right));
				builder.row(IrOpcode.Call, out, IrSymbol.of(name).id, where);
			case IrOpcode.ConstNull if (isCandidate(out)):
				builder.row(IrOpcode.ConstBool, present(out), 0, where);
				var value = payload(out);
				switch IrNullableScalarFlow.inner(body.valueType(out)) {
					case I32, I64:
						builder.row(IrOpcode.ConstInt, value, 0, where);
					case F32, F64:
						builder.row(IrOpcode.ConstFloat, value, builder.float(0), where);
					case Bool:
						builder.row(IrOpcode.ConstBool, value, 0, where);
					case other:
						throw new InternalError('Invalid nullable scalar payload $other');
				}
			case IrOpcode.ToDyn if (isCandidate(out)):
				builder.row(IrOpcode.ConstBool, present(out), 1, where);
			case IrOpcode.Phi if (isCandidate(out)):
				var count = body.operandCount(row);
				for (index in 0...count)
					builder.operandId(present(body.operand(row, index)));
				var start = builder.poolStart();
				for (index in 0...count)
					builder.int(body.auxInt(row, index));
				builder.row(IrOpcode.Phi, present(out), start, where);
				for (index in 0...count)
					builder.operandId(payload(body.operand(row, index)));
				start = builder.poolStart();
				for (index in 0...count)
					builder.int(body.auxInt(row, index));
				builder.row(IrOpcode.Phi, payload(out), start, where);
			case IrOpcode.SafeCast if (isCandidate(body.operand(row, 0))):
				var value = body.operand(row, 0),
					type = body.valueType(out),
					name = IrNullableScalarFlow.helperName(IrNullableScalarFlow.REQUIRE, type);
				need(IrNullableScalarFlow.REQUIRE, name, type);
				builder.operandId(present(value));
				builder.operandId(payload(value));
				builder.row(IrOpcode.Call, out, IrSymbol.of(name).id, where);
			case IrOpcode.Equal if (nullComparison(body, row)):
				var left = body.operand(row, 0),
					right = body.operand(row, 1),
					value = isNull(left) && isCandidate(right) ? right : left,
					no = IrValueId.of(next++);
				builder.defineValue(no, "$nullable-false", boolType);
				builder.row(IrOpcode.ConstBool, no, 0, where);
				builder.operandId(present(value));
				builder.operandId(no);
				builder.row(IrOpcode.Equal, out, 0, where);
			default:
				builder.copyRow(body, row);
		}
		return next;
	}

	/** Whether a call of candidate `called` passes each of its nullable arguments as a candidate, so it calls the specialization. */
	function expands(body:IrBody, row:Int, called:IrFunction):Bool {
		for (index in 0...body.operandCount(row))
			if (IrNullableScalarFlow.inner(called.arguments[index].type) != null
				&& !isCandidate(body.operand(row, index)))
				return false;
		return true;
	}

	function nullComparison(body:IrBody, row:Int):Bool {
		var left = body.operand(row, 0), right = body.operand(row, 1);
		return (isCandidate(left) && isNull(right)) || (isCandidate(right) && isNull(left));
	}
}
