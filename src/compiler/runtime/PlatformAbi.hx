package compiler.runtime;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Host types whose implementation is supplied by the HashLink/Haxe platform. */
class PlatformAbi {
	/** Stdlib class implementing `{...}` literals typed as Dynamic where the runtime has no dynamic objects. */
	public static inline final DYNAMIC_OBJECT_CLASS = "runtime.DynamicObject";

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
	 * They come with the declaring module, so the typer finds them loaded: one found while typing restarts the frontend.
	 */
	public static function implementationModules(module:String):Array<String>
		return module == "haxe.io.Bytes" ? ["haxe.io.BytesBounds"] : [];

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

	public static function method(type:CompilerType, name:String):Null<{
		arguments:Array<CompilerType>,
		result:CompilerType,
		nativeName:String
	}>
		return switch type {
			case CompilerType.TBytes: bytesMethod(name);
			case CompilerType.THlBytes:
				name == "ucs2Length" ? {
					arguments: [CompilerType.TInt], result: CompilerType.TInt, nativeName: "__hl_bytes_ucs2_length"
				} : null;
			case CompilerType.TAbstract(_, _, underlying): method(underlying, name);
			default: null;
		};

	static function bytesMethod(name:String):Null<{
		arguments:Array<CompilerType>,
		result:CompilerType,
		nativeName:String
	}>
		return switch name {
			case "getData": {
				arguments: noArguments(),
				result: CompilerType.THlBytes,
				nativeName: "__bytes_get_data"
			};
			case "get": {arguments: [CompilerType.TInt], result: CompilerType.TInt, nativeName: "__bytes_get"};
			case "getInt32": {arguments: [CompilerType.TInt], result: CompilerType.TInt, nativeName: "__bytes_get_i32"};
			case "getFloat": {
				arguments: [CompilerType.TInt],
				result: CompilerType.TFloat,
				nativeName: "__bytes_get_float"
			};
			case "getDouble": {
				arguments: [CompilerType.TInt],
				result: CompilerType.TFloat,
				nativeName: "__bytes_get_double"
			};
			case "set": {
				arguments: [CompilerType.TInt, CompilerType.TInt],
				result: CompilerType.TVoid,
				nativeName: "__bytes_try_set"
			};
			case "setInt32": {
				arguments: [CompilerType.TInt, CompilerType.TInt],
				result: CompilerType.TVoid,
				nativeName: "__bytes_try_set_i32"
			};
			case "setFloat": {
				arguments: [CompilerType.TInt, CompilerType.TFloat],
				result: CompilerType.TVoid,
				nativeName: "__bytes_try_set_float"
			};
			case "setDouble": {
				arguments: [CompilerType.TInt, CompilerType.TFloat],
				result: CompilerType.TVoid,
				nativeName: "__bytes_try_set_double"
			};
			case "blit": {
				arguments: [CompilerType.TInt, CompilerType.TBytes, CompilerType.TInt, CompilerType.TInt],
				result: CompilerType.TVoid,
				nativeName: "__bytes_try_blit"
			};
			case "compare": {arguments: [CompilerType.TBytes], result: CompilerType.TInt,
				nativeName: "__bytes_compare"};
			case "toString": {arguments: noArguments(), result: CompilerType.TString, nativeName: "__bytes_to_string"};
			// Haxe source in the stdlib (haxe/io/BytesBounds.hx), the same on every target.
			case "sub": {
				arguments: [CompilerType.TInt, CompilerType.TInt],
				result: CompilerType.TBytes,
				nativeName: "haxe.io.BytesBounds.sub"
			};
			case "getString": {
				arguments: [CompilerType.TInt, CompilerType.TInt],
				result: CompilerType.TString,
				nativeName: "haxe.io.BytesBounds.getString"
			};
			case "readString": {
				arguments: [CompilerType.TInt, CompilerType.TInt],
				result: CompilerType.TString,
				nativeName: "haxe.io.BytesBounds.readString"
			};
			// Haxe source in the stdlib (haxe/io/BytesAccess.hx), the same on every target.
			case "fill": {
				arguments: [CompilerType.TInt, CompilerType.TInt, CompilerType.TInt],
				result: CompilerType.TVoid,
				nativeName: "haxe.io.BytesAccess.fill"
			};
			case "getUInt16": {
				arguments: [CompilerType.TInt],
				result: CompilerType.TInt,
				nativeName: "haxe.io.BytesAccess.getUInt16"
			};
			case "setUInt16": {
				arguments: [CompilerType.TInt, CompilerType.TInt],
				result: CompilerType.TVoid,
				nativeName: "haxe.io.BytesAccess.setUInt16"
			};
			case "getInt64": {
				arguments: [CompilerType.TInt],
				result: CompilerType.TInt64,
				nativeName: "haxe.io.BytesAccess.getInt64"
			};
			case "setInt64": {
				arguments: [CompilerType.TInt, CompilerType.TInt64],
				result: CompilerType.TVoid,
				nativeName: "haxe.io.BytesAccess.setInt64"
			};
			// Haxe source in the stdlib (haxe/io/BytesHex.hx), the same on every target.
			case "toHex": {
				arguments: noArguments(),
				result: CompilerType.TString,
				nativeName: "haxe.io.BytesHex.toHex"
			};
			default: null;
		};

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

	static function noArguments():Array<CompilerType>
		return [];
}
