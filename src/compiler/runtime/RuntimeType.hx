package compiler.runtime;

import compiler.core.InternalError;
import compiler.core.StdlibNames;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/**
 * Names shared by the compiler-owned runtime ABI.
 *
 * Keeping these specializations in one place prevents the typer, IR builder,
 * and native registration table from silently drifting apart as collections
 * grow. Every new specialization has to be added here, typed, lowered, and
 * covered by an end-to-end runtime test.
 */
class RuntimeType {
	/** An intrinsic `Std`'s body calls (`Std.int` of a Float), registered with the compiler's other intrinsics or not at all. */
	static inline final STD_INTRINSIC = "__std_int_f64";

	/**
	 * The modules every program that has them includes from the start, because typing can make a body call them although no
	 * source names them, and whether it does is only known once bodies are typed: Dynamic values reach every program (the
	 * stdlib's own signatures take them), and so do Floats. With these and `companionModules`, the graph has every module typing
	 * calls before anything is typed (`RuntimeDependencyTracker` records the calls; the frontend checks them). A module is only
	 * one where what it calls exists: `Std`, and `haxeon.DynamicOps` and `Reflect`, which call it, need the compiler's intrinsics,
	 * which `hasNative` tells.
	 */
	public static function programModules(wasm:Bool, hasNative:String->Bool):Array<String> {
		var intrinsics = hasNative(STD_INTRINSIC);
		var modules = [
			for (module in [
				StdlibNames.HASH_MAP,
				StdlibNames.DYNAMIC_OPS,
				StdlibNames.REFLECT,
				StdlibNames.STD,
				StdlibNames.FLOAT_BITS,
				StdlibNames.INT64
			])
				if (intrinsics || (module != StdlibNames.DYNAMIC_OPS && module != StdlibNames.REFLECT
				&& module != StdlibNames.STD)) module
		];
		// Only targets without native dynamic objects allocate the stdlib's class for a Dynamic object literal.
		if (wasm)
			modules.push(StdlibNames.DYNAMIC_OBJECT);
		return modules;
	}

	/**
	 * The modules that come with `module` in the graph, because typing a use of what it declares makes a call into them that no
	 * source names. For built-in types without source modules, the dependency scan adds companions where source syntax can
	 * select them. Typing records the actual selections.
	 */
	public static function companionModules(module:String):Array<String>
		return switch module {
			case StdlibNames.OBSERVABLE: [StdlibNames.OBSERVABLE_SOURCE, StdlibNames.REACTIVE_RUNTIME];
			case "KeyValueIterable": [StdlibNames.ARRAY_METHODS, StdlibNames.MAP_METHODS];
			case "Map": [StdlibNames.OBJECT_MAP];
			default: PlatformAbi.implementationModules(module);
		};

	/** The implicit ObjectMap implementation uses Std, which requires the compiler intrinsics. */
	public static function hasCompanion(module:String, hasNative:String->Bool):Bool
		return module != StdlibNames.OBJECT_MAP || hasNative(STD_INTRINSIC);

	/**
	 * Whether the graph adds `module` before typing when typing can call it: a program module, a companion, or `haxe.StringCodes`, which
	 * the dependency scan adds where a source names `String.fromCharCode`. Typing may call no other module the source does not name.
	 */
	public static function isTypedDependency(module:String):Bool {
		if (module == StdlibNames.STRING_CODES || programModules(true, _ -> true).indexOf(module) >= 0)
			return true;
		for (owner in [StdlibNames.OBSERVABLE, StdlibNames.BYTES, "KeyValueIterable", "Map"])
			if (companionModules(owner).indexOf(module) >= 0)
				return true;
		return false;
	}

	/** Nullary enum keys use their existing integer representation in the generic map. */
	public static function specializedMapKey(key:CompilerType):CompilerType
		return switch key {
			case TAbstract(_, _, representation): specializedMapKey(representation);
			case TInstance(NominalKind.Enum, _, _): TInt;
			default: key;
		};

	public static function usesSpecializedMap(key:CompilerType, value:CompilerType, isValue:CompilerType->Bool,
			isHashable:CompilerType->Bool):Bool
		return isValue(key) || isValue(value) || (mapName(key, value) == null && isHashable(key));
	public static function arrayName(element:CompilerType):Null<String>
		return switch element {
			case TAbstract(_, _, representation): arrayName(representation);
			case TInt: "i32";
			case TNativeScalar("u32"): "i32";
			case TInt64: "i64";
			case TFloat: "f64";
			case TBool: "bool";
			case TString: "bytes";
			// IrGenerator lowers a nullable reference to the reference itself, so Array<Null<String>> holds strings.
			case TNullable(TString): "bytes";
			case TNullable(_): "ref";
			default: isRuntimeReference(element) ? "ref" : null;
		};

	public static function arrayNative(element:CompilerType, operation:String):String {
		var name = requireArrayName(element);
		return '__array_${operation}_$name';
	}

	public static function requireArrayName(element:CompilerType):String {
		var name = arrayName(element);
		if (name == null)
			throw new InternalError('Unsupported compiler array ABI for $element');
		return name;
	}

	public static function mapName(key:CompilerType, value:CompilerType):Null<String>
		return switch key {
			case TAbstract(_, _, representation): mapName(representation, value);
			case TString: mapValueName("map_string_", value);
			case TInt: mapValueName("map_int_", value);
			case TInstance(NominalKind.Enum, _, _): mapValueName("map_int_", value);
			default: null;
		};

	static function mapValueName(prefix:String, value:CompilerType):Null<String>
		return switch value {
			case TAbstract(_, _, representation): mapValueName(prefix, representation);
			case TNullable(element): nullableMapValueName(prefix, element);
			case TInt: prefix + "i32";
			case TInt64: prefix + "i64";
			case TBool: prefix + "bool";
			case TFloat: prefix + "f64";
			case TString: prefix + "bytes";
			default: isRuntimeReference(value) ? prefix + "ref" : null;
		};

	static function nullableMapValueName(prefix:String, element:CompilerType):Null<String>
		return switch element {
			case TAbstract(_, _, representation): nullableMapValueName(prefix, representation);
			case TString: prefix + "bytes";
			case TInt, TInt64, TBool, TFloat: prefix + "ref";
			default: isRuntimeReference(element) ? prefix + "ref" : null;
		};

	public static function mapKeyType(name:String):Null<CompilerType>
		return StringTools.startsWith(name, "map_int_") ? CompilerType.TInt : CompilerType.TString;

	public static function mapNative(key:CompilerType, value:CompilerType, operation:String):String {
		var name = requireMapName(key, value);
		return '__${name}_$operation';
	}

	public static function requireMapName(key:CompilerType, value:CompilerType):String {
		var name = mapName(key, value);
		if (name == null)
			throw new InternalError('Unsupported compiler map ABI for ${key} -> ${value}');
		return name;
	}

	public static function mapValueType(name:String):Null<CompilerType>
		return switch name {
			case "map_string_i32": CompilerType.TInt;
			case "map_string_i64": CompilerType.TInt64;
			case "map_string_bool": CompilerType.TBool;
			case "map_string_f64": CompilerType.TFloat;
			case "map_string_bytes": CompilerType.TString;
			case "map_int_i32": CompilerType.TInt;
			case "map_int_i64": CompilerType.TInt64;
			case "map_int_bool": CompilerType.TBool;
			case "map_int_f64": CompilerType.TFloat;
			case "map_int_bytes": CompilerType.TString;
			default: null;
		};

	/**
	 * True for a map of Int, Int64, Bool or Float values, which the runtime keeps unboxed. Such a map has no `get`
	 * native for compiled code: a lookup is `index` (the entry holding the key, or -1), then `value` of that entry.
	 */
	public static function hasScalarValues(name:String):Bool
		return switch mapValueType(name) {
			case TInt, TInt64, TBool, TFloat: true;
			default: false;
		};

	static function isRuntimeReference(type:CompilerType):Bool
		return switch type {
			case TAbstract(_, _, representation): isRuntimeReference(representation);
			case TBytes, THlBytes, TDynamic, TNativeAbstract(_), TAnonymous(_, _), TArray(_), TIterator(_), TMap(_, _),
				TFunction(_, _, _), TKeyPath(_, _, _): true;
			case TInstance(kind, _, _): kind != NominalKind.NativeValue;
			case TNullable(element): isRuntimeReference(element);
			// A type parameter left unsubstituted is erased to a boxed reference. Only a body typed for its signature in its own
			// type parameters (`DeclarationTypeTable`) sees one, and no code is generated from it.
			case TTypeParameter(_, _): true;
			default: false;
		};
}
