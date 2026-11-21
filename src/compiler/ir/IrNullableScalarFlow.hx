package compiler.ir;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.Ir;
import compiler.ir.IrFunction;

/**
 * Keep nonescaping nullable scalars in presence/payload SSA form across control-flow joins. Runs on bodies
 * (docs/design/IR_CORE_COLUMNS.md): each function is read as its body, and one that changes is rebuilt into a body this pass
 * owns, so a function nothing changes stays the same object.
 */
class IrNullableScalarFlow {
	public static inline final PREFIX = "$nullable-scalar:require:";
	public static inline final EQUAL_PREFIX = "$nullable-scalar:equal:";
	public static inline final CALL_PREFIX = "$nullable-scalar:arguments:";

	/**
	 * Rewrites `program`'s functions, reading them as bodies made with `types` (`IrTypeIds.ofFunctions` when not given): a
	 * function that changes becomes its edited body, owned by the next stage (`IrFunction.ofOwnedBody`).
	 */
	public static function rewrite(program:IrProgram, ?types:IrTypeIds, ?scratch:IrPassScratch):Void {
		if (types == null)
			types = IrTypeIds.ofFunctions(program.functions);
		if (scratch == null)
			scratch = new IrPassScratch();
		var builder = scratch.bodyBuilder;
		var checks:Map<String, IrType> = [],
			originals = program.functions.copy(),
			candidates:Map<String, IrFunction> = [];
		for (fn in originals) {
			var hasArgument = false;
			for (arg in fn.arguments)
				if (inner(arg.type) != null)
					hasArgument = true;
			if (hasArgument && inner(fn.result) == null && !isSpecialization(fn.name))
				candidates.set(fn.name, fn);
		}
		var flow = new IrBodyNullableScalars(scratch, candidates, checks);
		var changed = true;
		while (changed) {
			changed = false;
			for (name in [for (name in candidates.keys()) name])
				if (!flow.analyze(candidates.get(name).bodyIn(types, builder), true)) {
					candidates.remove(name);
					changed = true;
				}
		}
		program.functions = [for (fn in originals) rewritten(flow, fn, types, builder, false)];
		for (fn in originals)
			if (candidates.exists(fn.name))
				program.functions.push(rewritten(flow, fn, types, builder, true));
		var names = [for (name in checks.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var type = checks.get(name),
				builder = new IrBuilder(),
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
				program.functions.push(new IrFunction(name, builder.arguments, Bool, builder.blocks,
					Provider(TypeKey.of(type),
					ProviderOperations.detailed(ProviderOperation.NullableScalarHelper, "equal"))));
			} else {
				var yes = builder.createBlock(), no = builder.createBlock();
				builder.branch(present, yes, no);
				builder.select(yes);
				builder.returnValue(payload);
				builder.select(no);
				builder.terminate(Throw(builder.toDyn(builder.constString("Null access"))));
				program.functions.push(new IrFunction(name, builder.arguments, type, builder.blocks,
					Provider(TypeKey.of(type),
					ProviderOperations.detailed(ProviderOperation.NullableScalarHelper, "require"))));
			}
		}
	}

	/** `fn` with its nullable scalars split, or its specialization (`clone`); `fn` itself when nothing changes. */
	static function rewritten(flow:IrBodyNullableScalars, fn:IrFunction, types:IrTypeIds, builder:IrBodyBuilder,
			clone:Bool):IrFunction {
		var body = fn.bodyIn(types, builder);
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
class IrBodyNullableScalars {
	static inline final CANDIDATE = 1;
	static inline final NULL = 2;

	final scratch:IrPassScratch;
	final functions:Map<String, IrFunction>;
	final checks:Map<String, IrType>;

	/** By value id: CANDIDATE while it is one, NULL when a null constant defines it. */
	var states:Array<Int>;

	/** The candidates in the order they were found, rejected ones included. */
	var order:Array<Int>;

	/** By candidate value id, its presence flag's id (the payload's is the next); by payload id, the value that replaces it or -1. */
	var parts:Array<Int>;

	var substitutions:Array<Int>;
	var body:IrBody;
	var changed = false;

	public function new(scratch:IrPassScratch, functions:Map<String, IrFunction>, checks:Map<String, IrType>) {
		this.scratch = scratch;
		this.functions = functions;
		this.checks = checks;
		states = scratch.firstInts;
		order = scratch.pendingIds;
		parts = scratch.secondInts;
		substitutions = scratch.thirdInts;
		body = null;
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
	public function analyze(source:IrBody, clone:Bool):Bool {
		body = source;
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
					rejectUses(row);
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
	function calledCandidate(row:Int):Null<IrFunction> {
		var called = functions.get(body.symbol(row).name);
		return called != null && called.arguments.length == body.operandCount(row) ? called : null;
	}

	function isEqualityOfNullables(row:Int):Bool {
		if (body.symbol(row).name != "__dynamic_equal" || body.operandCount(row) != 2)
			return false;
		var left = body.valueType(body.operand(row, 0));
		return Type.enumEq(left, body.valueType(body.operand(row, 1))) && IrNullableScalarFlow.inner(left) != null;
	}

	function rejectUses(row:Int):Void {
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
			case IrOpcode.Call if (functions.exists(body.symbol(row).name)):
				var called = calledCandidate(row), eligible = called != null;
				if (called != null)
					for (index in 0...count)
						if (IrNullableScalarFlow.inner(called.arguments[index].type) != null
							&& !isCandidate(body.operand(row, index)))
							eligible = false;
				if (!eligible)
					for (index in 0...count)
						reject(body.operand(row, index));
			case IrOpcode.Call if (isEqualityOfNullables(row)):
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
					if (isCandidate(value) && !allowedUse(opcode, row, index, value))
						reject(value);
				}
		}
	}

	function allowedUse(opcode:IrOpcode, row:Int, index:Int, value:IrValueId):Bool
		return switch opcode {
			case IrOpcode.SafeCast:
				index == 0
					&& Type.enumEq(body.valueType(body.output(row)), IrNullableScalarFlow.inner(body.valueType(value)));
			case IrOpcode.Equal:
				var left = body.operand(row, 0), right = body.operand(row, 1);
				(left == value && isNull(right)) || (right == value && isNull(left));
			default:
				false;
		};

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
	public function build(source:IrBody, builder:IrBodyBuilder, clone:Bool):IrBody {
		body = source;
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
				body.typeId(IrNullableScalarFlow.inner(body.valueType(id))));
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
				next = buildRow(builder, row, next, boolType);
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
	function buildRow(builder:IrBodyBuilder, row:Int, next:Int, boolType:Int):Int {
		var where = body.provenance(row), out = body.output(row);
		switch body.opcode(row) {
			case IrOpcode.Call if (functions.exists(body.symbol(row).name)):
				var called = calledCandidate(row), name = body.symbol(row).name;
				if (called == null || !expands(row, called)) {
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
			case IrOpcode.Call if (isEqualityOfNullables(row) && isCandidate(body.operand(row, 0))
				&& isCandidate(body.operand(row, 1))):
				var left = body.operand(row, 0),
					right = body.operand(row, 1),
					type = IrNullableScalarFlow.inner(body.valueType(left)),
					name = IrNullableScalarFlow.EQUAL_PREFIX + IrTypeIdentity.text(type);
				checks.set(name, type);
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
					name = IrNullableScalarFlow.PREFIX + IrTypeIdentity.text(type);
				checks.set(name, type);
				builder.operandId(present(value));
				builder.operandId(payload(value));
				builder.row(IrOpcode.Call, out, IrSymbol.of(name).id, where);
			case IrOpcode.Equal if (nullComparison(row)):
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
	function expands(row:Int, called:IrFunction):Bool {
		for (index in 0...body.operandCount(row))
			if (IrNullableScalarFlow.inner(called.arguments[index].type) != null
				&& !isCandidate(body.operand(row, index)))
				return false;
		return true;
	}

	function nullComparison(row:Int):Bool {
		var left = body.operand(row, 0), right = body.operand(row, 1);
		return (isCandidate(left) && isNull(right)) || (isCandidate(right) && isNull(left));
	}
}
