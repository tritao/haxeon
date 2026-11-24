package compiler.runtime;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Host types whose implementation is supplied by the HashLink/Haxe platform. */
class PlatformAbi {
	/** Stdlib class implementing `{...}` literals typed as Dynamic where the runtime has no dynamic objects. */
	public static inline final DYNAMIC_OBJECT_CLASS = "runtime.DynamicObject";

	/** The module declaring `haxe.io.Bytes`, whose methods the platform implements. */
	public static inline final BYTES = "haxe.io.Bytes";

	static final types:Map<String, Bool> = [
		"haxe.io.Encoding" => true,
		"haxe.Json" => true,
		"sys.io.File" => true,
		"Type.ValueType" => true
	];

	/**
	 * The stdlib module a platform method or field getter is written in, or null for a runtime native (named `__...`): a
	 * use must load that module, which its callers may not otherwise name.
	 */
	public static function sourceModule(target:String):Null<String> {
		if (StringTools.startsWith(target, "__"))
			return null;
		var dot = target.lastIndexOf(".");
		return dot <= 0 ? null : target.substr(0, dot);
	}

	/**
	 * The stdlib modules that implement methods of the platform types `module` declares, which a call of one adds to the program.
	 * They come with the declaring module, so the typer finds them loaded: the graph has them before any call is typed.
	 */
	public static function implementationModules(module:String):Array<String> {
		if (module != BYTES)
			return [];
		var modules:Map<String, Bool> = [];
		for (nativeName in [OUTSIDE_BOUNDS].concat([for (method in bytesMethods) method.nativeName])) {
			var implementation = sourceModule(nativeName);
			if (implementation != null)
				modules.set(implementation, true);
		}
		var sorted = [for (implementation in modules.keys()) implementation];
		sorted.sort(Reflect.compare);
		return sorted;
	}

	public static function isType(name:String):Bool
		return types.exists(name);

	/** Whether a platform-owned type may carry a compile-time native ABI tag. */
	public static function acceptsNativeTag(name:String):Bool
		return name == "hl.Abstract";

	public static function constructorArguments(name:String):Null<Array<CompilerType>>
		return switch name {
			default: null;
		};

	public static function valueType(name:String):CompilerType
		return switch name {
			default: CompilerType.TInstance(NominalKind.Class, name, []);
		};

	public static function constructorNative(name:String):Null<String>
		return switch name {
			default: null;
		};

	public static function field(type:CompilerType, name:String):Null<{type:CompilerType, get:String, set:Null<String>}>
		return switch type {
			case CompilerType.TString:
				name == "bytes" ? {
					type: CompilerType.THlBytes,
					get: "__string_bytes",
					set: null
				} : null;
			case CompilerType.TBytes: name == "length" ? {
				type: CompilerType.TInt, get: "__bytes_length", set: null
			} : null;
			// Haxe source in the stdlib (haxe/Int64.hx), the same on every target.
			case CompilerType.TInt64: name == "low" ? {
				type: CompilerType.TInt, get: "haxe.Int64.int64Low", set: null
			} : name == "high" ? {
				type: CompilerType.TInt, get: "haxe.Int64.int64High", set: null
			} : null;
			case CompilerType.TAbstract(_, _, underlying): field(underlying, name);
			default: null;
		};

	public static function method(type:CompilerType, name:String):Null<PlatformMethod>
		return switch type {
			case CompilerType.TBytes: bytesMethods.get(name);
			case CompilerType.THlBytes:
				name == "ucs2Length" ? {
					arguments: [CompilerType.TInt], result: CompilerType.TInt, nativeName: "__hl_bytes_ucs2_length"
				} : null;
			case CompilerType.TAbstract(_, _, underlying): method(underlying, name);
			default: null;
		};

	/** The methods of `haxe.io.Bytes` the platform implements, by name. */
	static final bytesMethods:Map<String, PlatformMethod> = [
		"getData" => platformMethod([], THlBytes, "__bytes_get_data"),
		"get" => platformMethod([TInt], TInt, "__bytes_get"),
		"getInt32" => platformMethod([TInt], TInt, "__bytes_get_i32"),
		"getFloat" => platformMethod([TInt], TFloat, "__bytes_get_float"),
		"getDouble" => platformMethod([TInt], TFloat, "__bytes_get_double"),
		"set" => platformMethod([TInt, TInt], TVoid, "__bytes_try_set"),
		"setInt32" => platformMethod([TInt, TInt], TVoid, "__bytes_try_set_i32"),
		"setFloat" => platformMethod([TInt, TFloat], TVoid, "__bytes_try_set_float"),
		"setDouble" => platformMethod([TInt, TFloat], TVoid, "__bytes_try_set_double"),
		"blit" => platformMethod([TInt, TBytes, TInt, TInt], TVoid, "__bytes_try_blit"),
		"compare" => platformMethod([TBytes], TInt, "__bytes_compare"),
		"toString" => platformMethod([], TString, "__bytes_to_string"),
		// Haxe source in the stdlib (haxe/io/BytesBounds.hx), the same on every target.
		"sub" => platformMethod([TInt, TInt], TBytes, "haxe.io.BytesBounds.sub"),
		"getString" => platformMethod([TInt, TInt], TString, "haxe.io.BytesBounds.getString"),
		"readString" => platformMethod([TInt, TInt], TString, "haxe.io.BytesBounds.readString"),
		// Haxe source in the stdlib (haxe/io/BytesAccess.hx), the same on every target.
		"fill" => platformMethod([TInt, TInt, TInt], TVoid, "haxe.io.BytesAccess.fill"),
		"getUInt16" => platformMethod([TInt], TInt, "haxe.io.BytesAccess.getUInt16"),
		"setUInt16" => platformMethod([TInt, TInt], TVoid, "haxe.io.BytesAccess.setUInt16"),
		"getInt64" => platformMethod([TInt], TInt64, "haxe.io.BytesAccess.getInt64"),
		"setInt64" => platformMethod([TInt, TInt64], TVoid, "haxe.io.BytesAccess.setInt64"),
		// Haxe source in the stdlib (haxe/io/BytesHex.hx), the same on every target.
		"toHex" => platformMethod([], TString, "haxe.io.BytesHex.toHex")
	];

	/**
	 * Whether a platform method's native returns whether its range was inside the bytes, where Haxe throws
	 * `haxe.io.Error.OutsideBounds` when it was not: the call is typed as the method's result, after that check.
	 */
	public static function signalsOutsideBounds(nativeName:String):Bool
		return switch nativeName {
			case "__bytes_try_set", "__bytes_try_set_i32", "__bytes_try_set_float", "__bytes_try_set_double",
				"__bytes_try_blit": true;
			default: false;
		};

	/** The stdlib function that throws Haxe's `haxe.io.Error.OutsideBounds`. */
	public static inline final OUTSIDE_BOUNDS = "haxe.io.BytesBounds.outsideBounds";

	static function platformMethod(arguments:Array<CompilerType>, result:CompilerType, nativeName:String):PlatformMethod
		return {arguments: arguments, result: result, nativeName: nativeName};
}

/** A method of a platform type: its signature, and the native or stdlib function a call of it calls. */
typedef PlatformMethod = {
	arguments:Array<CompilerType>,
	result:CompilerType,
	nativeName:String
}
