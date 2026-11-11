package compiler.ir;

import compiler.Provides.ProviderOperation;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;
import compiler.types.typing.EnumDynamicBox;
import compiler.types.typing.EnumRuntimeType;

/** Dispatch Dynamic enum operations by the concrete runtime enum descriptor. */
class IrEnumDynamicDispatch {
	public static inline final EQUAL = "$enum-dynamic-equal";
	public static inline final REFLECT = "$enum-dynamic-reflect";

	public static function rewrite(functions:Array<IrFunction>):Array<IrFunction> {
		// One descriptor per enum type, keyed by the type's key; the equality helpers come from the provider table, the boxes and views
		// from the requests the functions carry. No name is parsed.
		var requests:Map<String, IrType> = [], boxes:Map<String, IrType> = [], views:Map<String, IrType> = [],
			equalityOf:Map<String, Array<String>> = [], reflectiveOf:Map<String, Array<String>> = [],
			functionNames:Map<String, Bool> = [for (fn in functions) fn.name => true], needsEqual = false, needsReflect = false;
		function register(type:IrType):String {
			var key = TypeKey.of(type).toString(), previous = requests.get(key);
			if (previous != null && !IrVerifier.sameType(previous, type)) throw 'Conflicting enum Dynamic descriptor "$key"';
			requests.set(key, type);
			return key;
		}
		// Two source types can lower to one enum type, each with its own helper: a key can have several.
		function provide(table:Map<String, Array<String>>, key:String, helper:String):Void {
			var list = table.get(key);
			if (list == null) {
				list = [];
				table.set(key, list);
			}
			list.push(helper);
		}
		for (fn in functions) {
			switch fn.provides {
				case Serves(type, operation) if (type.isEnum() && fn.arguments.length == 2):
					switch fn.arguments[0].type {
						case Enum(_):
							switch IrProviders.base(operation) {
								case ProviderOperation.Equals: provide(equalityOf, register(fn.arguments[0].type), fn.name);
								case ProviderOperation.ReflectEquals: provide(reflectiveOf, register(fn.arguments[0].type), fn.name);
								default:
							}
						default:
					}
				default:
			}
			for (request in fn.requests)
				switch request.operation {
					case ProviderOperation.BoxDynamic:
						if (!isEnum(request.type)) throw 'Enum Dynamic escape "${request.name}" requires an enum value';
						register(request.type);
						boxes.set(request.name, request.type);
					case ProviderOperation.ViewDynamic:
						if (!isEnum(request.type)) throw 'Enum Dynamic array view "${request.name}" requires an enum type';
						register(request.type);
						views.set(request.name, request.type);
					default:
				}
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case Call(_, "__dynamic_equal", _): needsEqual = true;
				case Call(_, REFLECT, _): needsReflect = true;
				default:
			}
		}
		var names = [for (key in requests.keys()) key]; names.sort(Reflect.compare);
		// Descriptor discovery above still needs every concrete reflected enum. Its structural
		// equality body is needed only when a reachable Type.enumEq operation can call it.
		if (!needsReflect) functions = pruneReflectiveHelpers(functions);
		var boxNames = [for (name in boxes.keys()) name]; boxNames.sort(Reflect.compare);
		for (name in boxNames) if (!functionNames.exists(name)) {
			var type = boxes.get(name), builder = new IrBuilder(), value = builder.argument("value", type);
			builder.returnValue(builder.toDyn(value)); functions.push(new IrFunction(name, builder.arguments, Dyn, builder.blocks, Serves(TypeKey.of(type), ProviderOperation.BoxDynamic), []));
			functionNames.set(name, true);
		}
		var viewNames = [for (name in views.keys()) name]; viewNames.sort(Reflect.compare);
		for (name in viewNames) if (!functionNames.exists(name)) {
			var builder = new IrBuilder(), array = builder.argument("array", Array(Dyn));
			builder.returnValue(array); functions.push(new IrFunction(name, builder.arguments, Array(Dyn), builder.blocks, Serves(TypeKey.of(views.get(name)), ProviderOperation.ViewDynamic), []));
			functionNames.set(name, true);
		}
		var rewritten:Array<IrFunction> = [], unboxes:Map<String, IrType> = [], typeTests:Map<String, {type:IrType, exact:Bool}> = [];
		// The type values of the function being rewritten, found only when it makes a type test.
		var current:Null<IrFunction> = null, typeValuesOfCurrent:Null<Map<Int, IrType>> = null;
		function typeValues():Map<Int, IrType> {
			if (typeValuesOfCurrent == null) {
				typeValuesOfCurrent = [];
				for (block in current.blocks) for (located in block.instructions) switch located.value {
					case TypeValue(output, type): typeValuesOfCurrent.set(output.id, type);
					default:
				}
			}
			return typeValuesOfCurrent;
		}
		function replacement(located:Located<IrInstruction>):Null<Array<Located<IrInstruction>>>
			return switch located.value {
				case Call(output, "__dynamic_equal", arguments) if (names.length > 0):
					[new Located(Call(output, EQUAL, arguments), located.provenance)];
				case SafeCast(output, input) if (IrVerifier.sameType(input.type, Dyn) && isEnum(output.type)):
					var helper = unboxName(output.type); unboxes.set(helper, output.type);
					[new Located(Call(output, helper, [input]), located.provenance)];
				case Call(output, name, arguments) if (names.length > 0 && (name == "__std_is_of_type" || name == "__std_is_exact_type")
					&& arguments.length == 2 && typeValues().exists(arguments[1].id) && isEnum(typeValues().get(arguments[1].id))):
					var type = typeValues().get(arguments[1].id), exact = name == "__std_is_exact_type", helper = typeTestName(type, exact);
					typeTests.set(helper, {type: type, exact: exact});
					[new Located(Call(output, helper, [arguments[0]]), located.provenance)];
				default: null;
			};
		for (fn in functions) {
			current = fn;
			typeValuesOfCurrent = null;
			rewritten.push(IrFunctionRewrite.instructions(fn, replacement));
		}
		var unboxNames = [for (name in unboxes.keys()) name]; unboxNames.sort(Reflect.compare);
		for (name in unboxNames) rewritten.push(unbox(name, unboxes.get(name)));
		var testNames = [for (name in typeTests.keys()) name]; testNames.sort(Reflect.compare);
		for (name in testNames) { var test = typeTests.get(name); rewritten.push(typeTest(name, test.type, test.exact, names, requests)); }
		if (needsEqual && names.length > 0) rewritten.push(dispatcher(EQUAL, names, requests, equalityOf));
		if (needsReflect) rewritten.push(dispatcher(REFLECT, names, requests, reflectiveOf));
		return rewritten;
	}

	/** Keep typed reflective equality roots and their nested enum dependencies. */
	static function pruneReflectiveHelpers(functions:Array<IrFunction>):Array<IrFunction> {
		var helpers:Map<String, IrFunction> = [], live:Map<String, Bool> = [], pending:Array<String> = [];
		for (fn in functions)
			switch fn.provides {
				case Serves(type, operation) if (type.isEnum() && IrProviders.base(operation) == ProviderOperation.ReflectEquals): helpers.set(fn.name, fn);
				default:
			}
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
			if (!helpers.exists(fn.name)) scan(fn);
			else if (fn.retention != compiler.ir.IrFunction.IrRetention.Reachable) mark(fn.name);
		var index = 0;
		while (index < pending.length) scan(helpers.get(pending[index++]));
		return [for (fn in functions) if (!helpers.exists(fn.name) || live.exists(fn.name)) fn];
	}

	static function isEnum(type:IrType):Bool return switch type { case Enum(_): true; default: false; };
	static function unboxName(type:IrType):String return "$enum-dynamic-unbox:" + haxe.crypto.Base64.encode(compiler.ir.codec.IrTypeCodec.encode(type));
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
		return new IrFunction(name, builder.arguments, type, builder.blocks, Serves(TypeKey.of(type), ProviderOperation.DynamicUnbox), []);
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
		return new IrFunction(name, builder.arguments, Bool, builder.blocks, Serves(TypeKey.of(type), ProviderOperation.DynamicTest), []);
	}

	/** Enums have equality but no declared ordering. Never order their boxed addresses. */
	static function dispatcher(name:String, names:Array<String>, requests:Map<String, IrType>, equalityOf:Map<String, Array<String>>):IrFunction {
		var builder = new IrBuilder(), left = builder.argument("left", Dyn), right = builder.argument("right", Dyn);
		for (boxName in names) {
			var helpers = equalityOf.get(boxName), type = requests.get(boxName);
			if (helpers == null) helpers = [null] else { helpers = helpers.copy(); helpers.sort(Reflect.compare); }
			// One case per helper in the order of their names, as before: the first that matches runs.
			for (equality in helpers) {
				var matched = builder.createBlock(), next = builder.createBlock(), same = builder.createBlock(), different = builder.createBlock();
				builder.branch(builder.call("__std_is_exact_type", [left, builder.typeValue(type)], Bool), matched, next);
				builder.select(matched);
				builder.branch(builder.call("__std_is_exact_type", [right, builder.typeValue(type)], Bool), same, different);
				builder.select(different); builder.returnValue(builder.constBool(false));
				builder.select(same);
				if (equality != null) builder.returnValue(builder.call(equality, [builder.safeCast(left, type), builder.safeCast(right, type)], Bool));
				else builder.throwValue(builder.toDyn(builder.constString("Enum value does not conform to Equatable")));
				builder.select(next);
			}
		}
		builder.returnValue(builder.call("__dynamic_equal", [left, right], Bool));
		return new IrFunction(name, builder.arguments, Bool, builder.blocks, None, []);
	}
}
