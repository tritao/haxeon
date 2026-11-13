package compiler.ir;

import compiler.Provides.ProviderOperation;
import compiler.Provides.ProviderOperation;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Select a boxed struct's declared equality at a Dynamic boundary. */
class IrValueDynamicDispatch {
	static inline final EQUAL = "$value-dynamic-equal";
	static inline final EQUALITY_PREFIX = "$value$equality:";

	static function isValueEquality(fn:IrFunction):Bool
		return switch fn.provides {
			case Serves(type, operation): !type.isEnum() && IrProviders.base(operation) == ProviderOperation.Equals;
			case None: false;
		};

	/** With `unreached` (the functions a plain build's walk did not reach) and `createdClasses`, only reached equality helpers and structs that can exist register; otherwise every one does. */
	public static function rewrite(functions:Array<IrFunction>, objects:Array<IrObject>, ?unreached:Map<String, Bool>,
			?createdClasses:Map<String, Bool>):Array<IrFunction> {
		var values:Map<String, Bool> = [for (object in objects) if (object.isValue) object.name => true];
		var names = new IrFunctionIndex("value-dynamic-dispatch", functions);
		var objectsByName:Map<String, IrObject> = [for (object in objects) object.name => object];
		// A struct that declares Equatable has an equality provider; one that does not must still throw at run time when compared.
		function declaredEquatable(type:IrType):Bool {
			var current = switch type { case Obj(name): objectsByName.get(name); default: null; };
			while (current != null) {
				if (current.interfaces.indexOf("Equatable") >= 0)
					return true;
				current = current.base == null ? null : objectsByName.get(current.base);
			}
			return false;
		}
		var requests:Map<String, IrType> = [], registeredValues:Map<String, Bool> = [], needsEqual = false;
		function valueType(type:IrType):Null<IrType> return switch type {
			case Nullable(inner): valueType(inner);
			case Obj(name) if (values.exists(name)): type;
			default: null;
		};
		function register(suffix:String, type:IrType):Void {
			var value = valueType(type);
			if (value == null) throw 'Dynamic struct boundary "$suffix" has no value type';
			var previous = requests.get(suffix);
			if (previous != null && !IrVerifier.sameType(previous, value)) throw 'Conflicting Dynamic struct descriptor "$suffix"';
			requests.set(suffix, value);
			switch value { case Obj(name): registeredValues.set(name, true); default: }
		}
		// Reflection can box a field without a source-level conversion. Its requested
		// equality function still carries the concrete value type in its signature.
		for (fn in functions) if ((unreached == null || !unreached.exists(fn.name)) && isValueEquality(fn) && fn.arguments.length == 2
				&& (switch fn.arguments[0].type { case Obj(name): values.exists(name); default: false; }))
			register(fn.name.substr(EQUALITY_PREFIX.length), fn.arguments[0].type);
		for (fn in functions) if (unreached == null || !unreached.exists(fn.name)) for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case Call(_, "__dynamic_equal", _): needsEqual = true;
			default:
		}
		// A reflected value need not appear in any explicit Dynamic conversion.
		// Still reject equality for a nonconforming reflected struct.
		for (object in objects) if (object.isValue && !registeredValues.exists(object.name) && (createdClasses == null || createdClasses.exists(object.name)))
			register("$reflected:" + object.name, Obj(object.name));
		var suffixes = [for (suffix in requests.keys()) suffix]; suffixes.sort(Reflect.compare);
		function replacement(located:Located<IrInstruction>):Null<Array<Located<IrInstruction>>>
			return switch located.value {
				case Call(output, "__dynamic_equal", arguments) if (suffixes.length > 0): [new Located(Call(output, EQUAL, arguments), located.provenance)];
				default: null;
			};
		var rewritten:Array<IrFunction> = [for (fn in functions) IrFunctionRewrite.instructions(fn, replacement)];
		if (needsEqual && suffixes.length > 0) rewritten.push(dispatcher(suffixes, requests, names, declaredEquatable));
		return rewritten;
	}

	static function dispatcher(suffixes:Array<String>, requests:Map<String, IrType>, names:IrFunctionIndex, declaredEquatable:IrType->Bool):IrFunction {
		var builder = new IrBuilder(), left = builder.argument("left", Dyn), right = builder.argument("right", Dyn);
		var byId:Map<Int, Array<String>> = [];
		for (suffix in suffixes) {
			var id = IrTypeIdentity.id(requests.get(suffix)), group = byId.get(id);
			if (group == null) byId.set(id, group = []);
			group.push(suffix);
		}
		var ids = [for (id in byId.keys()) id];
		var actual = builder.call("__dynamic_object_type_id", [left], I32), fallback = builder.createBlock();
		IrTypeHashDispatch.emit(builder, actual, ids, function(id) {
			for (suffix in byId.get(id)) {
				var type = requests.get(suffix), matched = builder.createBlock(), next = builder.createBlock(),
					same = builder.createBlock(), different = builder.createBlock(), equality = EQUALITY_PREFIX + suffix;
				builder.branch(builder.call("__std_is_exact_type", [left, builder.typeValue(type)], Bool), matched, next);
				builder.select(matched);
				builder.branch(builder.call("__std_is_exact_type", [right, builder.typeValue(type)], Bool), same, different);
				builder.select(different); builder.returnValue(builder.constBool(false));
				builder.select(same);
				if (names.exists(equality)) builder.returnValue(builder.call(equality, [builder.safeCast(left, type), builder.safeCast(right, type)], Bool));
				else if (declaredEquatable(type)) throw 'internal error: struct "${Std.string(type)}" declares Equatable but has no equality provider ($equality)';
				else builder.throwValue(builder.toDyn(builder.constString("Struct value does not conform to Equatable")));
				builder.select(next);
			}
			builder.jump(fallback);
		}, fallback);
		builder.select(fallback);
		builder.returnValue(builder.call("__dynamic_equal", [left, right], Bool));
		return new IrFunction(EQUAL, builder.arguments, Bool, builder.blocks, GeneratedHelper);
	}
}
