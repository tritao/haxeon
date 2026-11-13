package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;
import compiler.types.typing.EnumRuntimeType;

/** Dispatch Dynamic enum operations by the concrete runtime enum descriptor. */
class IrEnumDynamicDispatch {
	public static inline final EQUAL = "$enum-dynamic-equal";
	public static inline final REFLECT = "$enum-dynamic-reflect";

	/** With `unreached` (the functions a plain build's walk did not reach), only the others register what they need and are rewritten; otherwise every function does. */
	public static function rewrite(functions:Array<IrFunction>, ?reflectionProgram:IrProgram, ?reflectableObjects:Array<String>,
			?unreached:Map<String, Bool>):Array<IrFunction> {
		var requests:Map<String, IrType> = [], boxes:Map<String, Bool> = [], views:Map<String, Bool> = [],
			equalities:Map<String, String> = [], reflectiveEqualities:Map<String, String> = [],
			occupied:Map<String, Bool> = [for (fn in functions) fn.name => true],
			needsEqual = false, needsReflect = false;
		function key(type:IrType):String return Std.string(type);
		function register(type:IrType):String { var id = key(type); requests.set(id, type); return id; }
		for (fn in functions) {
			switch fn.kind {
				case EnumEquality(reflective) if (fn.arguments.length == 2 && isEnum(fn.arguments[0].type)):
					var id = key(fn.arguments[0].type);
				(reflective ? reflectiveEqualities : equalities).set(id, fn.name);
				default:
			}
			if (unreached == null || !unreached.exists(fn.name)) for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case Intrinsic(output, EnumDynamicBox(type), arguments):
					if (!isEnum(type) || arguments.length != 1 || !IrVerifier.sameType(arguments[0].type, type)
						|| !IrVerifier.sameType(output.type, Dyn)) throw "Invalid enum Dynamic box signature";
					boxes.set(register(type), true);
				case Intrinsic(output, EnumDynamicView(type), arguments):
					if (!isEnum(type) || arguments.length != 1 || !IrVerifier.sameType(arguments[0].type, Array(Dyn))
						|| !IrVerifier.sameType(output.type, Array(Dyn))) throw "Invalid enum Dynamic view signature";
					views.set(register(type), true);
				case Call(_, "__dynamic_equal", _): needsEqual = true;
				case Call(_, REFLECT, _): needsReflect = true;
				default:
			}
		}
		// Only observable enum descriptors need reflective dispatch. Preserve the upstream
		// reachability decision while identifying equality helpers by their declared role.
		if (reflectionProgram != null) {
			var roots:Array<IrType> = [];
			if (ObjectReflection.usesObjectLayouts(reflectionProgram.natives)) {
				if (reflectableObjects != null) for (name in reflectableObjects) roots.push(Obj(name));
				for (object in reflectionProgram.objects)
					if (compiler.semantic.SemanticSignature.isAnonymousName(object.name)) roots.push(Obj(object.name));
			}
			for (native in reflectionProgram.natives) if (!IrArrayRuntimeNatives.isStorage(native.name)) {
				for (argument in native.arguments) IrEnumEscapeReach.addNativeRoot(roots, argument);
				IrEnumEscapeReach.addNativeRoot(roots, native.result);
			}
			for (native in reflectionProgram.cNatives) {
				for (argument in native.arguments) IrEnumEscapeReach.addNativeRoot(roots, argument);
				IrEnumEscapeReach.addNativeRoot(roots, native.result);
			}
			var observed = new IrEnumEscapeReach(reflectionProgram).collect(roots, _ -> false);
			for (fn in functions) switch fn.kind {
				case EnumEquality(_) if (fn.arguments.length == 2):
					switch fn.arguments[0].type { case Enum(name) if (observed.exists(name)): register(fn.arguments[0].type); default: }
				default:
			}
		}
		var reflectiveRoots:Array<String> = [];
		if (needsReflect) for (id in requests.keys()) {
			var helper = reflectiveEqualities.get(id);
			if (helper != null) reflectiveRoots.push(helper);
		}
		functions = pruneReflectiveHelpers(functions, reflectiveRoots);
		for (fn in functions) if (unreached == null || !unreached.exists(fn.name)) switch fn.kind {
			case EnumEquality(true) if (fn.arguments.length == 2 && isEnum(fn.arguments[0].type)): register(fn.arguments[0].type);
			default:
		}
		var names = [for (name in requests.keys()) name]; names.sort(Reflect.compare);
		var boxNames:Map<String, String> = [], viewNames:Map<String, String> = [], unboxNames:Map<String, String> = [];
		for (index in 0...names.length) {
			var id = names[index];
			boxNames.set(id, symbol(occupied, "$haxeon_enum_dynamic_box_" + index));
			viewNames.set(id, symbol(occupied, "$haxeon_enum_dynamic_view_" + index));
			unboxNames.set(id, symbol(occupied, "$haxeon_enum_dynamic_unbox_" + index));
		}
		for (id in names) {
			if (boxes.exists(id)) {
				var builder = new IrBuilder(), value = builder.argument("value", requests.get(id));
				builder.returnValue(builder.toDyn(value)); functions.push(new IrFunction(boxNames.get(id), builder.arguments, Dyn, builder.blocks, GeneratedHelper));
			}
			if (views.exists(id)) {
				var builder = new IrBuilder(), array = builder.argument("array", Array(Dyn));
				builder.returnValue(array); functions.push(new IrFunction(viewNames.get(id), builder.arguments, Array(Dyn), builder.blocks, GeneratedHelper));
			}
		}
		var rewritten:Array<IrFunction> = [], unboxes:Map<String, IrType> = [], typeTests:Map<String, {type:IrType, exact:Bool}> = [], nextExtraUnbox = 0;
		for (fn in functions) {
			if (unreached != null && unreached.exists(fn.name)) {
				rewritten.push(fn);
				continue;
			}
			var blocks:Array<IrBlock> = [], changed = false, typeValues:Map<Int, IrType> = [];
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case TypeValue(output, type): typeValues.set(output.id, type);
				default:
			}
			for (block in fn.blocks) {
				var target = new IrBlock(block.id);
				for (located in block.instructions) switch located.value {
					case Intrinsic(output, EnumDynamicBox(type), arguments):
						target.instructions.push(new Located(Call(output, boxNames.get(key(type)), arguments), located.provenance)); changed = true;
					case Intrinsic(output, EnumDynamicView(type), arguments):
						target.instructions.push(new Located(Call(output, viewNames.get(key(type)), arguments), located.provenance)); changed = true;
					case Call(output, "__dynamic_equal", arguments) if (names.length > 0):
						target.instructions.push(new Located(Call(output, EQUAL, arguments), located.provenance)); changed = true;
					case SafeCast(output, input) if (IrVerifier.sameType(input.type, Dyn) && isEnum(output.type)):
						var id = key(output.type), helper = unboxNames.get(id);
						if (helper == null) { helper = symbol(occupied, "$haxeon_enum_dynamic_unbox_extra_" + nextExtraUnbox++); unboxNames.set(id, helper); }
						unboxes.set(helper, output.type);
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
		var usedUnboxNames = [for (name in unboxes.keys()) name]; usedUnboxNames.sort(Reflect.compare);
		for (name in usedUnboxNames) rewritten.push(unbox(name, unboxes.get(name)));
		var testNames = [for (name in typeTests.keys()) name]; testNames.sort(Reflect.compare);
		for (name in testNames) { var test = typeTests.get(name); rewritten.push(typeTest(name, test.type, test.exact, names, requests)); }
		if (needsEqual && names.length > 0) rewritten.push(dispatcher(EQUAL, names, requests, equalities));
		if (needsReflect) rewritten.push(dispatcher(REFLECT, names, requests, reflectiveEqualities));
		return rewritten;
	}

	/** Keep typed reflective equality roots and their nested enum dependencies. */
	static function pruneReflectiveHelpers(functions:Array<IrFunction>, roots:Array<String>):Array<IrFunction> {
		var helpers:Map<String, IrFunction> = [], live:Map<String, Bool> = [], pending:Array<String> = [];
		for (fn in functions) switch fn.kind { case EnumEquality(true): helpers.set(fn.name, fn); default: }
		function mark(name:String):Void {
			if (helpers.exists(name) && !live.exists(name)) { live.set(name, true); pending.push(name); }
		}
		for (name in roots) mark(name);
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
	static function symbol(occupied:Map<String, Bool>, base:String):String {
		var name = base, suffix = 0;
		while (occupied.exists(name)) name = base + "_" + suffix++;
		occupied.set(name, true);
		return name;
	}
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
		return new IrFunction(name, builder.arguments, type, builder.blocks, EnumDynamicUnbox(type));
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
	static function dispatcher(name:String, names:Array<String>, requests:Map<String, IrType>, equalities:Map<String, String>):IrFunction {
		var builder = new IrBuilder(), left = builder.argument("left", Dyn), right = builder.argument("right", Dyn);
		for (boxName in names) {
			var type = requests.get(boxName),
				matched = builder.createBlock(), next = builder.createBlock(), same = builder.createBlock(), different = builder.createBlock(),
				equality = equalities.get(boxName);
			builder.branch(builder.call("__std_is_exact_type", [left, builder.typeValue(type)], Bool), matched, next);
			builder.select(matched);
			builder.branch(builder.call("__std_is_exact_type", [right, builder.typeValue(type)], Bool), same, different);
			builder.select(different); builder.returnValue(builder.constBool(false));
			builder.select(same);
			if (equality != null) builder.returnValue(builder.call(equality, [builder.safeCast(left, type), builder.safeCast(right, type)], Bool));
			else builder.throwValue(builder.toDyn(builder.constString("Enum value does not conform to Equatable")));
			builder.select(next);
		}
		builder.returnValue(builder.call("__dynamic_equal", [left, right], Bool));
		return new IrFunction(name, builder.arguments, Bool, builder.blocks, GeneratedHelper);
	}
}
