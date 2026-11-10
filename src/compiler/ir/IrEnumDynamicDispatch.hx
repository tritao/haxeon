package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;
import compiler.types.typing.EnumDynamicBox;
import compiler.types.typing.EnumRuntimeType;

/** Dispatch Dynamic enum operations by the concrete runtime enum descriptor. */
class IrEnumDynamicDispatch {
	public static inline final UNBOX_PREFIX = "$enum-dynamic-unbox:";
	public static inline final EQUAL = "$enum-dynamic-equal";
	public static inline final REFLECT = "$enum-dynamic-reflect";

	public static function rewrite(functions:Array<IrFunction>):Array<IrFunction> {
		var requests:Map<String, IrType> = [], boxes:Map<String, Bool> = [], views:Map<String, Bool> = [],
			functionNames:Map<String, Bool> = [for (fn in functions) fn.name => true], needsEqual = false, needsReflect = false;
		function register(name:String, type:IrType):Void {
			var previous = requests.get(name);
			if (previous != null && !IrVerifier.sameType(previous, type)) throw 'Conflicting enum Dynamic descriptor "$name"';
			requests.set(name, type);
		}
		for (fn in functions) {
			var prefix = StringTools.startsWith(fn.name, "$enum-equals:") ? "$enum-equals:"
				: StringTools.startsWith(fn.name, "$enum-reflect-equals:") ? "$enum-reflect-equals:" : null;
			if (prefix != null && fn.arguments.length == 2) switch fn.arguments[0].type {
				case Enum(_): register(EnumDynamicBox.PREFIX + fn.name.substr(prefix.length), fn.arguments[0].type);
				default:
			}
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case Call(output, name, arguments) if (StringTools.startsWith(name, EnumDynamicBox.PREFIX)):
					if (arguments.length != 1 || !IrVerifier.sameType(output.type, Dyn)) throw 'Invalid enum Dynamic escape "$name"';
					switch arguments[0].type {
						case Enum(_): register(name, arguments[0].type); boxes.set(name, true);
						default: throw 'Enum Dynamic escape "$name" requires an enum value';
					}
				case Call(output, name, arguments) if (StringTools.startsWith(name, EnumDynamicBox.VIEW_PREFIX)):
					if (arguments.length != 1 || !IrVerifier.sameType(output.type, Array(Dyn)) || !IrVerifier.sameType(arguments[0].type, Array(Dyn)))
						throw 'Invalid enum Dynamic array view "$name"';
					var parts = name.substr(EnumDynamicBox.VIEW_PREFIX.length).split(":");
					if (parts.length != 2) throw 'Invalid enum Dynamic array view name "$name"';
					register(EnumDynamicBox.PREFIX + parts[0], Enum(haxe.crypto.Base64.decode(parts[1]).toString())); views.set(name, true);
				case Call(_, "__dynamic_equal", _): needsEqual = true;
				case Call(_, REFLECT, _): needsReflect = true;
				default:
			}
		}
		var names = [for (name in requests.keys()) name]; names.sort(Reflect.compare);
		// Descriptor discovery above still needs every concrete reflected enum. Its structural
		// equality body is needed only when a reachable Type.enumEq operation can call it.
		if (!needsReflect) functions = pruneReflectiveHelpers(functions);
		var boxNames = [for (name in boxes.keys()) name]; boxNames.sort(Reflect.compare);
		for (name in boxNames) if (!functionNames.exists(name)) {
			var builder = new IrBuilder(), value = builder.argument("value", requests.get(name));
			builder.returnValue(builder.toDyn(value)); functions.push(new IrFunction(name, builder.arguments, Dyn, builder.blocks, GeneratedHelper));
			functionNames.set(name, true);
		}
		var viewNames = [for (name in views.keys()) name]; viewNames.sort(Reflect.compare);
		for (name in viewNames) if (!functionNames.exists(name)) {
			var builder = new IrBuilder(), array = builder.argument("array", Array(Dyn));
			builder.returnValue(array); functions.push(new IrFunction(name, builder.arguments, Array(Dyn), builder.blocks, GeneratedHelper));
			functionNames.set(name, true);
		}
		var rewritten:Array<IrFunction> = [], unboxes:Map<String, IrType> = [], typeTests:Map<String, {type:IrType, exact:Bool}> = [];
		for (fn in functions) {
			var blocks:Array<IrBlock> = [], changed = false, typeValues:Map<Int, IrType> = [];
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case TypeValue(output, type): typeValues.set(output.id, type);
				default:
			}
			for (block in fn.blocks) {
				var target = new IrBlock(block.id);
				for (located in block.instructions) switch located.value {
					case Call(output, "__dynamic_equal", arguments) if (names.length > 0):
						target.instructions.push(new Located(Call(output, EQUAL, arguments), located.provenance)); changed = true;
					case SafeCast(output, input) if (IrVerifier.sameType(input.type, Dyn) && isEnum(output.type)):
						var helper = unboxName(output.type); unboxes.set(helper, output.type);
						target.instructions.push(new Located(Call(output, helper, [input]), located.provenance)); changed = true;
					case Call(output, name, arguments) if (names.length > 0 && (name == "__std_is_of_type" || name == "__std_is_exact_type")
						&& arguments.length == 2 && typeValues.exists(arguments[1].id) && isEnum(typeValues.get(arguments[1].id))):
						var type = typeValues.get(arguments[1].id), exact = name == "__std_is_exact_type", helper = typeTestName(type, exact);
						typeTests.set(helper, {type: type, exact: exact});
						target.instructions.push(new Located(Call(output, helper, [arguments[0]]), located.provenance)); changed = true;
					default: target.instructions.push(located);
				}
				target.terminator = block.terminator; blocks.push(target);
			}
			rewritten.push(changed ? fn.withBlocks(blocks) : fn);
		}
		var unboxNames = [for (name in unboxes.keys()) name]; unboxNames.sort(Reflect.compare);
		for (name in unboxNames) rewritten.push(unbox(name, unboxes.get(name)));
		var testNames = [for (name in typeTests.keys()) name]; testNames.sort(Reflect.compare);
		for (name in testNames) { var test = typeTests.get(name); rewritten.push(typeTest(name, test.type, test.exact, names, requests)); }
		if (needsEqual && names.length > 0) rewritten.push(dispatcher(EQUAL, false, names, requests, functionNames));
		if (needsReflect) rewritten.push(dispatcher(REFLECT, true, names, requests, functionNames));
		return rewritten;
	}

	/** Keep typed reflective equality roots and their nested enum dependencies. */
	static function pruneReflectiveHelpers(functions:Array<IrFunction>):Array<IrFunction> {
		var prefix = "$enum-reflect-equals:", helpers:Map<String, IrFunction> = [], live:Map<String, Bool> = [], pending:Array<String> = [];
		for (fn in functions) if (StringTools.startsWith(fn.name, prefix)) helpers.set(fn.name, fn);
		function mark(name:String):Void {
			if (helpers.exists(name) && !live.exists(name)) { live.set(name, true); pending.push(name); }
		}
		function scan(fn:IrFunction):Void {
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case Call(_, name, _), StaticClosure(_, name), InstanceClosure(_, name, _): mark(name);
				default:
			}
		}
		for (fn in functions)
			if (!StringTools.startsWith(fn.name, prefix)) scan(fn);
			else if (fn.retention != compiler.ir.IrFunction.IrRetention.Reachable) mark(fn.name);
		var index = 0;
		while (index < pending.length) scan(helpers.get(pending[index++]));
		return [for (fn in functions) if (!StringTools.startsWith(fn.name, prefix) || live.exists(fn.name)) fn];
	}

	static function isEnum(type:IrType):Bool return switch type { case Enum(_): true; default: false; };
	public static function unboxName(type:IrType):String return UNBOX_PREFIX + haxe.crypto.Base64.encode(compiler.ir.codec.IrTypeCodec.encode(type));
	static function typeTestName(type:IrType, exact:Bool):String
		return "$enum-dynamic-test:" + (exact ? "exact:" : "instance:") + haxe.crypto.Base64.encode(compiler.ir.codec.IrTypeCodec.encode(type));

	static function unbox(name:String, type:IrType):IrFunction {
		var builder = new IrBuilder(), input = builder.argument("value", Dyn), absent = builder.createBlock(), test = builder.createBlock(),
			matched = builder.createBlock(), invalid = builder.createBlock();
		builder.branch(builder.equal(input, builder.constNull(Dyn)), absent, test);
		builder.select(absent); builder.returnValue(builder.constNull(type));
		builder.select(test); builder.branch(builder.call("__std_is_exact_type", [input, builder.typeValue(type)], Bool), matched, invalid);
		builder.select(matched); builder.returnValue(builder.safeCast(input, type));
		builder.select(invalid); builder.throwValue(builder.toDyn(builder.constString("Invalid enum cast")));
		return new IrFunction(name, builder.arguments, type, builder.blocks, GeneratedHelper);
	}

	static function typeTest(name:String, type:IrType, exact:Bool, names:Array<String>, requests:Map<String, IrType>):IrFunction {
		var builder = new IrBuilder(), input = builder.argument("value", Dyn), targetName = switch type { case Enum(value): value; default: ""; },
			declaration = EnumRuntimeType.declaration(targetName), family = declaration == targetName;
		for (boxName in names) {
			var candidate = requests.get(boxName), candidateName = switch candidate { case Enum(value): value; default: ""; };
			if (!IrVerifier.sameType(candidate, type) && !(family && EnumRuntimeType.declaration(candidateName) == declaration)) continue;
			var matched = builder.createBlock(), next = builder.createBlock();
			builder.branch(builder.call(exact ? "__std_is_exact_type" : "__std_is_of_type", [input, builder.typeValue(candidate)], Bool), matched, next);
			builder.select(matched); builder.returnValue(builder.constBool(true)); builder.select(next);
		}
		builder.returnValue(builder.call(exact ? "__std_is_exact_type" : "__std_is_of_type", [input, builder.typeValue(type)], Bool));
		return new IrFunction(name, builder.arguments, Bool, builder.blocks, GeneratedHelper);
	}

	/** Enums have equality but no declared ordering. Never order their boxed addresses. */
	static function dispatcher(name:String, reflective:Bool, names:Array<String>, requests:Map<String, IrType>, functionNames:Map<String, Bool>):IrFunction {
		var builder = new IrBuilder(), left = builder.argument("left", Dyn), right = builder.argument("right", Dyn);
		for (boxName in names) {
			var type = requests.get(boxName), suffix = boxName.substr(EnumDynamicBox.PREFIX.length),
				matched = builder.createBlock(), next = builder.createBlock(), same = builder.createBlock(), different = builder.createBlock(),
				equality = (reflective ? "$enum-reflect-equals:" : "$enum-equals:") + suffix;
			builder.branch(builder.call("__std_is_exact_type", [left, builder.typeValue(type)], Bool), matched, next);
			builder.select(matched);
			builder.branch(builder.call("__std_is_exact_type", [right, builder.typeValue(type)], Bool), same, different);
			builder.select(different); builder.returnValue(builder.constBool(false));
			builder.select(same);
			if (functionNames.exists(equality)) builder.returnValue(builder.call(equality, [builder.safeCast(left, type), builder.safeCast(right, type)], Bool));
			else builder.throwValue(builder.toDyn(builder.constString("Enum value does not conform to Equatable")));
			builder.select(next);
		}
		builder.returnValue(builder.call("__dynamic_equal", [left, right], Bool));
		return new IrFunction(name, builder.arguments, Bool, builder.blocks, GeneratedHelper);
	}
}
