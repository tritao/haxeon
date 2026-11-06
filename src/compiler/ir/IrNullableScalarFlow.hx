package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

private typedef NullableScalarParts = {final present:IrValue; final payload:IrValue;}
private typedef NullableScalarRewrite = {final fn:IrFunction; final eligible:Bool;}

/** Keep nonescaping nullable scalars in presence/payload SSA form across control-flow joins. */
class IrNullableScalarFlow {
	static inline final PREFIX = "$nullable-scalar:require:";
	static inline final EQUAL_PREFIX = "$nullable-scalar:equal:";
	public static inline final CALL_PREFIX = "$nullable-scalar:arguments:";

	public static function rewrite(program:IrProgram):Void {
		var checks:Map<String, IrType> = [], originals = program.functions.copy(), candidates:Map<String, IrFunction> = [];
		for (fn in originals) {
			var hasArgument = false;
			for (arg in fn.arguments) if (inner(arg.type) != null) hasArgument = true;
			if (hasArgument && inner(fn.result) == null && !isSpecialization(fn.name)) candidates.set(fn.name, fn);
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (name in [for (name in candidates.keys()) name])
				if (!rewriteFunction(candidates.get(name), [], candidates, true).eligible) { candidates.remove(name); changed = true; }
		}
		program.functions = [for (fn in originals) rewriteFunction(fn, checks, candidates, false).fn];
		for (fn in originals) if (candidates.exists(fn.name)) program.functions.push(rewriteFunction(fn, checks, candidates, true).fn);
		var names = [for (name in checks.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var type = checks.get(name), builder = new IrBuilder(), present = builder.argument("present", Bool),
				payload = builder.argument("payload", type);
			if (StringTools.startsWith(name, EQUAL_PREFIX)) {
				var otherPresent = builder.argument("other-present", Bool), otherPayload = builder.argument("other-payload", type),
					same = builder.createBlock(), different = builder.createBlock(), absent = builder.createBlock(), compare = builder.createBlock();
				builder.branch(builder.equal(present, otherPresent), same, different);
				builder.select(different); builder.returnValue(builder.constBool(false));
				builder.select(same); builder.branch(present, compare, absent);
				builder.select(absent); builder.returnValue(builder.constBool(true));
				builder.select(compare); builder.returnValue(builder.equal(payload, otherPayload));
				program.functions.push(new IrFunction(name, builder.arguments, Bool, builder.blocks));
			} else {
				var yes = builder.createBlock(), no = builder.createBlock();
				builder.branch(present, yes, no);
				builder.select(yes); builder.returnValue(payload);
				builder.select(no); builder.terminate(Throw(builder.toDyn(builder.constString("Null access"))));
				program.functions.push(new IrFunction(name, builder.arguments, type, builder.blocks));
			}
		}
	}

	/** Nullable argument expansion preserves an existing scalar result/stack-reference ABI. */
	static function specializationName(name:String):String {
		var scalar = IrScalarArguments.PREFIX;
		return StringTools.startsWith(name, scalar) ? scalar + CALL_PREFIX + name.substr(scalar.length) : CALL_PREFIX + name;
	}

	static function isSpecialization(name:String):Bool
		return StringTools.startsWith(name, CALL_PREFIX) || StringTools.startsWith(name, IrScalarArguments.PREFIX + CALL_PREFIX);

	static function inner(type:IrType):Null<IrType> return switch type {
		case Nullable(I32): I32;
		case Nullable(I64): I64;
		case Nullable(F32): F32;
		case Nullable(F64): F64;
		case Nullable(Bool): Bool;
		default: null;
	};

	static function zero(value:IrValue):IrInstruction return switch value.type {
		case I32, I64: ConstInt(value, 0);
		case F32, F64: ConstFloat(value, 0);
		case Bool: ConstBool(value, false);
		default: throw 'Invalid nullable scalar payload ${value.type}';
	};

	static function rewriteFunction(fn:IrFunction, checks:Map<String, IrType>, functions:Map<String, IrFunction>, clone:Bool):NullableScalarRewrite {
		var candidates:Map<Int, IrValue> = [], nulls:Map<Int, Bool> = [], next = 0;
		for (argument in fn.arguments) {
			if (argument.id >= next) next = argument.id + 1;
			if (clone && inner(argument.type) != null) candidates.set(argument.id, argument);
		}
		for (block in fn.blocks) for (located in block.instructions) {
			var instruction = located.value, out = IrOperands.output(instruction);
			if (out != null && out.id >= next) next = out.id + 1;
			for (input in IrOperands.inputs(instruction)) if (input.id >= next) next = input.id + 1;
			if (out != null && inner(out.type) != null) switch instruction {
				case ConstNull(_): candidates.set(out.id, out); nulls.set(out.id, true);
				case ToDyn(_, value) if (Type.enumEq(value.type, inner(out.type))): candidates.set(out.id, out);
				case Phi(_, _): candidates.set(out.id, out);
				default:
			}
		}
		// All uses of a component value must be expressible without reconstructing its box.
		// Remove whole connected phi groups when any boundary escapes or has an unsupported operation.
		var changed = true;
		while (changed) {
			changed = false;
			function reject(value:IrValue):Void if (candidates.remove(value.id)) changed = true;
			for (block in fn.blocks) {
				for (located in block.instructions) {
					var instruction = located.value;
					switch instruction {
						case Phi(out, inputs):
							var eligible = candidates.exists(out.id);
							for (input in inputs) if (!candidates.exists(input.value.id)) eligible = false;
							if (!eligible) { reject(out); for (input in inputs) reject(input.value); }
						case Call(_, name, args) if (functions.exists(name)):
							var called = functions.get(name), eligible = args.length == called.arguments.length;
							if (eligible) for (index in 0...args.length)
								if (inner(called.arguments[index].type) != null && !candidates.exists(args[index].id)) eligible = false;
							if (!eligible) for (arg in args) reject(arg);
						case Call(_, "__dynamic_equal", args) if (args.length == 2 && Type.enumEq(args[0].type, args[1].type)
								&& inner(args[0].type) != null):
							if (!candidates.exists(args[0].id) || !candidates.exists(args[1].id)) for (arg in args) reject(arg);
						default:
							for (value in IrOperands.inputs(instruction)) if (candidates.exists(value.id)) {
								var allowed = switch instruction {
									case SafeCast(out, input) if (input.id == value.id && Type.enumEq(out.type, inner(value.type))): true;
									case Equal(_, left, right) if ((left.id == value.id && nulls.exists(right.id))
											|| (right.id == value.id && nulls.exists(left.id))): true;
									default: false;
								};
								if (!allowed) reject(value);
							}
					}
				}
				if (block.terminator != null) switch block.terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _): reject(value);
					default:
				}
			}
		}
		var eligible = true;
		if (clone) for (argument in fn.arguments) if (inner(argument.type) != null && !candidates.exists(argument.id)) eligible = false;
		if (!eligible || !candidates.keys().hasNext()) return {fn: fn, eligible: eligible};
		var parts:Map<Int, NullableScalarParts> = [];
		for (id => value in candidates) parts.set(id, {present: new IrValue(next++, "$nullable-present", Bool),
			payload: new IrValue(next++, "$nullable-payload", inner(value.type))});
		function required(value:IrValue):NullableScalarParts {
			var result = parts.get(value.id);
			if (result == null) throw 'Missing nullable scalar components for ${value.id}';
			return result;
		}
		var arguments:Array<IrValue> = [];
		for (argument in fn.arguments) {
			if (clone && parts.exists(argument.id)) { var part = required(argument); arguments.push(part.present); arguments.push(part.payload); }
			else arguments.push(argument);
		}
		var substitutions:Map<Int, IrValue> = [], blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var target = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = located.value;
				switch instruction {
					case Call(out, name, args) if (functions.exists(name)):
						var called = functions.get(name), use = args.length == called.arguments.length;
						if (use) for (index in 0...args.length)
							if (inner(called.arguments[index].type) != null && !parts.exists(args[index].id)) use = false;
						if (use) {
							var expanded:Array<IrValue> = [];
							for (index in 0...args.length) if (inner(called.arguments[index].type) != null) {
								var part = required(args[index]); expanded.push(part.present); expanded.push(part.payload);
							} else expanded.push(args[index]);
							target.instructions.push(new Located(Call(out, specializationName(name), expanded), located.provenance));
						} else target.instructions.push(located);
					case Call(out, "__dynamic_equal", args) if (args.length == 2 && parts.exists(args[0].id) && parts.exists(args[1].id)
							&& Type.enumEq(args[0].type, args[1].type)):
						var left = required(args[0]), right = required(args[1]), type = inner(args[0].type), name = EQUAL_PREFIX + Std.string(type);
						checks.set(name, type);
						target.instructions.push(new Located(Call(out, name, [left.present, left.payload, right.present, right.payload]), located.provenance));
					case ConstNull(out) if (parts.exists(out.id)):
						var part = required(out);
						target.instructions.push(new Located(ConstBool(part.present, false), located.provenance));
						target.instructions.push(new Located(zero(part.payload), located.provenance));
					case ToDyn(out, value) if (parts.exists(out.id)):
						var part = required(out);
						target.instructions.push(new Located(ConstBool(part.present, true), located.provenance));
						substitutions.set(part.payload.id, value);
					case Phi(out, inputs) if (parts.exists(out.id)):
						var part = required(out);
						target.instructions.push(new Located(Phi(part.present, [for (input in inputs) {block: input.block, value: required(input.value).present}]), located.provenance));
						target.instructions.push(new Located(Phi(part.payload, [for (input in inputs) {block: input.block, value: required(input.value).payload}]), located.provenance));
					case SafeCast(out, value) if (parts.exists(value.id)):
						var part = required(value), name = PREFIX + Std.string(out.type);
						checks.set(name, out.type);
						target.instructions.push(new Located(Call(out, name, [part.present, part.payload]), located.provenance));
					case Equal(out, left, right) if ((parts.exists(left.id) && nulls.exists(right.id)) || (parts.exists(right.id) && nulls.exists(left.id))):
						var value = nulls.exists(left.id) && parts.exists(right.id) ? right : left,
							no = new IrValue(next++, "$nullable-false", Bool);
						target.instructions.push(new Located(ConstBool(no, false), located.provenance));
						target.instructions.push(new Located(Equal(out, required(value).present, no), located.provenance));
					default: target.instructions.push(located);
				}
			}
			target.terminator = block.terminator;
			blocks.push(target);
		}
		var debug = [for (binding in fn.debugBindings) if (!parts.exists(binding.value.id)) binding];
		debug = IrInliner.substitute(blocks, substitutions, debug);
		return {fn: new IrFunction(clone ? specializationName(fn.name) : fn.name, arguments, fn.result, blocks, debug, fn.inlineHint,
			clone ? compiler.ir.IrFunction.IrRetention.Reachable : fn.retention), eligible: true};
	}
}
