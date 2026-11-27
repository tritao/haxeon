package compiler.core;

/**
 * The standard-library declarations the compiler knows by name: the types it checks for, the modules it loads, and the
 * functions it calls or recognizes. The compiler names them only through this table, so moving a declaration changes one
 * line here (ADR 0007). Each name is the declaration's path as the compiler sees it: a module's secondary type is
 * `package.Type`, as `haxe.EnumValueTools` for `haxe.EnumTools.EnumValueTools`.
 *
 * Types the compiler builds in (`Int`, `String`, `Array`, `Map`, `Iterator`, `Type`, ...) are not here: they have no
 * declaration in the standard library to move. Nor is the Haxe source the FFI binding generator writes, which names the
 * standard library as any source does.
 */
class StdlibNames {
	// Root declarations: the interfaces a type conforms to, and the modules Haxe code calls without an import.

	public static inline final EQUATABLE = "Equatable";
	public static inline final HASHABLE = "Hashable";
	public static inline final DIFFABLE = "Diffable";
	public static inline final DISPOSABLE = "Disposable";
	/** The interface an observable class implements, whose generated field access calls the reactive runtime. */
	public static inline final OBSERVABLE = "Observable";
	public static inline final MUST_USE = "MustUse";
	public static inline final FLAGS = "Flags";
	public static inline final RESULT = "Result";

	/** The class a regular expression literal constructs. */
	public static inline final EREG = "EReg";

	/** `Std.string`, which converts a Float or a Dynamic value to a String. */
	public static inline final STD = "Std";
	public static inline final STD_STRING = "Std.string";
	public static inline final STD_STD_STRING = "Std.stdString";
	public static inline final STD_ARRAY_STRING = "Std.arrayString";
	public static inline final STD_INT = "Std.int";
	public static inline final STD_INT_FLOAT = "Std.stdIntFloat";
	public static inline final STD_IS_OF_TYPE = "Std.isOfType";
	public static inline final STD_IS_EXACT_TYPE = "Std.isExactType";
	public static inline final STD_DOWNCAST = "Std.downcast";

	/** Field access and method calls on a Dynamic value, and its copy into an anonymous structure, call `Reflect`. */
	public static inline final REFLECT = "Reflect";
	public static inline final REFLECT_FIELD = "Reflect.field";
	public static inline final REFLECT_SET_FIELD = "Reflect.setField";
	public static inline final REFLECT_HAS_FIELD = "Reflect.hasField";
	public static inline final REFLECT_IS_FUNCTION = "Reflect.isFunction";
	public static inline final REFLECT_IS_OBJECT = "Reflect.isObject";
	public static inline final REFLECT_COMPARE = "Reflect.compare";

	public static inline final MATH = "Math";
	public static inline final MATH_CEIL = "Math.ceil";
	public static inline final MATH_FLOOR = "Math.floor";
	public static inline final MATH_IS_NAN = "Math.mathIsNaN";
	public static inline final MATH_IS_FINITE = "Math.mathIsFinite";

	public static inline final STRING_TOOLS = "StringTools";

	// haxe

	public static inline final INT64 = "haxe.Int64";
	public static inline final INT64_MAKE = "haxe.Int64.make";
	public static inline final INT64_OF_INT = "haxe.Int64.ofInt";
	public static inline final INT64_TO_INT = "haxe.Int64.toInt";
	public static inline final INT64_FROM_FLOAT = "haxe.Int64.fromFloat";
	public static inline final INT64_HIGH = "haxe.Int64.int64High";
	public static inline final INT64_LOW = "haxe.Int64.int64Low";
	public static inline final INT64_ADD = "haxe.Int64.add";
	public static inline final INT64_SUB = "haxe.Int64.sub";
	public static inline final INT64_MUL = "haxe.Int64.mul";
	public static inline final INT64_DIV = "haxe.Int64.div";
	public static inline final INT64_MOD = "haxe.Int64.mod";
	public static inline final INT64_NEG = "haxe.Int64.neg";
	public static inline final INT64_AND = "haxe.Int64.and";
	public static inline final INT64_OR = "haxe.Int64.or";
	public static inline final INT64_XOR = "haxe.Int64.xor";
	public static inline final INT64_SHL = "haxe.Int64.shl";
	public static inline final INT64_SHR = "haxe.Int64.shr";
	public static inline final INT64_USHR = "haxe.Int64.ushr";
	public static inline final INT64_COMPARE = "haxe.Int64.compare";

	/** The module declaring `haxe.io.Bytes`, whose methods the platform implements. */
	public static inline final BYTES = "haxe.io.Bytes";

	public static inline final BYTES_ALLOC = "haxe.io.Bytes.alloc";
	public static inline final BYTES_SUB = "haxe.io.BytesBounds.sub";
	public static inline final BYTES_GET_STRING = "haxe.io.BytesBounds.getString";
	public static inline final BYTES_READ_STRING = "haxe.io.BytesBounds.readString";

	/** The function that throws Haxe's `haxe.io.Error.OutsideBounds`. */
	public static inline final BYTES_OUTSIDE_BOUNDS = "haxe.io.BytesBounds.outsideBounds";

	public static inline final BYTES_FILL = "haxe.io.BytesAccess.fill";
	public static inline final BYTES_GET_UINT16 = "haxe.io.BytesAccess.getUInt16";
	public static inline final BYTES_SET_UINT16 = "haxe.io.BytesAccess.setUInt16";
	public static inline final BYTES_GET_INT64 = "haxe.io.BytesAccess.getInt64";
	public static inline final BYTES_SET_INT64 = "haxe.io.BytesAccess.setInt64";
	public static inline final BYTES_TO_HEX = "haxe.io.BytesHex.toHex";
	public static inline final ENCODING = "haxe.io.Encoding";
	public static inline final JSON = "haxe.Json";
	public static inline final FILE = "sys.io.File";
	public static inline final REST = "haxe.Rest";
	public static inline final POS_INFOS = "haxe.PosInfos";

	/** The class whose statics turn a thrown value into what a catch clause tests (`TypedCatchSubject`). */
	public static inline final EXCEPTION = "haxe.Exception";

	/** `haxe.Exception.caught(value)`: the thrown exception, or a `haxe.ValueException` wrapping any other value. */
	public static inline final EXCEPTION_CAUGHT = "haxe.Exception.caught";

	/** `haxe.Exception.caughtValue(value)`: what `caught(value).unwrap()` gives, without wrapping a value that is no exception. */
	public static inline final EXCEPTION_CAUGHT_VALUE = "haxe.Exception.caughtValue";

	public static inline final OBJECT_MAP = "haxe.ds.ObjectMap";

	/** The module that implements `String.fromCharCode` in Haxe on a target whose runtime does not (Wasm). */
	public static inline final STRING_CODES = "haxe.StringCodes";

	public static inline final STRING_CODES_FROM_CHAR_CODE = "haxe.StringCodes.fromCharCode";

	/** The class `haxe.EnumTools.EnumValueTools` is, as the compiler names a module's secondary type. */
	public static inline final ENUM_VALUE_TOOLS = "haxe.EnumValueTools";

	// hl

	public static inline final HL_BYTES = "hl.Bytes";
	public static inline final HL_ABSTRACT = "hl.Abstract";

	// runtime: the implementation the compiler lowers to.

	/** The bits of a Float, which a generated hash of a Float reads as an Int64. */
	public static inline final FLOAT_BITS = "runtime.FloatBits";

	public static inline final FLOAT_BITS_TO_INT32 = "runtime.FloatBits.toInt32";
	public static inline final FLOAT_BITS_FROM_INT32 = "runtime.FloatBits.fromInt32";
	public static inline final FLOAT_BITS_TO_INT64 = "runtime.FloatBits.toInt64";
	public static inline final FLOAT_BITS_FROM_INT64 = "runtime.FloatBits.fromInt64";
	public static inline final RYU_FORMAT = "runtime.Ryu.format";
	public static inline final RUNTIME_DATA_ADDRESS = "runtime.RuntimeData.address";
	public static inline final RUNTIME_DATA_LOAD_I32 = "runtime.RuntimeData.loadI32";
	public static inline final RUNTIME_DATA_STRING_FROM_ASCII = "runtime.RuntimeData.stringFromAscii";

	/** The class implementing `{...}` literals typed as Dynamic where the runtime has no dynamic objects. */
	public static inline final DYNAMIC_OBJECT = "runtime.DynamicObject";

	public static inline final NATIVE_SPAN = "runtime.memory.NativeSpan";
	public static inline final RAW_PTR = "runtime.memory.RawPtr";

	// haxeon

	/** The operators whose operand is Dynamic, which the typer calls where an operand is Dynamic. */
	public static inline final DYNAMIC_OPS = "haxeon.DynamicOps";

	public static inline final DYNAMIC_OPS_INDEX = "haxeon.DynamicOps.index";
	public static inline final DYNAMIC_OPS_SET_INDEX = "haxeon.DynamicOps.setIndex";
	public static inline final ARRAY_METHODS = "haxeon.ArrayMethods";
	public static inline final MAP_METHODS = "haxeon.MapMethods";
	public static inline final HASH_MAP = "haxeon.collections.HashMap";
	public static inline final OBSERVABLE_SOURCE = "haxeon.reactive.ObservableSource";
	public static inline final REACTIVE_RUNTIME = "haxeon.reactive.ReactiveRuntime";
	public static inline final OBSERVABLE_WRITE_STATUS = "haxeon.reactive.ReactiveRuntime.observableWriteStatus";
	public static inline final RECORD_OBSERVABLE_CREATION = "haxeon.reactive.ReactiveRuntime.recordObservableCreation";
	public static inline final REACTIVE_HASH = "haxeon.reactive.ReactiveHash.reactiveHash";
	public static inline final EQUALITY_EQUALS = "haxeon.Equality.equals";
	public static inline final EQUALITY_SAME_FOR_CHANGE = "haxeon.Equality.sameForChange";
	public static inline final HASHING_HASH = "haxeon.Hashing.hash";
	public static inline final HASHING_KEY_EQUALS = "haxeon.Hashing.keyEquals";
	public static inline final DIFF_COPY = "haxeon.Diff.copy";
	public static inline final DIFF_MASK = "haxeon.Diff.mask";
	public static inline final DIFF_APPLY = "haxeon.Diff.apply";
	public static inline final DIFF_BIT = "haxeon.Diff.bit";
	public static inline final DIFF_ALL = "haxeon.Diff.all";
	public static inline final DIFF_FINGERPRINT = "haxeon.Diff.fingerprint";

	/** What a switch over a closed set throws for a value none of its cases name (`BodyTyper.unmatchedValue`). */
	public static inline final UNMATCHED_VALUE = "haxeon.UnmatchedValue";

	public static inline final MESSAGE_PACK_ENCODE = "haxeon.wire.MessagePack.encode";
	public static inline final MESSAGE_PACK_DECODE = "haxeon.wire.MessagePack.decode";
	public static inline final MESSAGE_PACK_WRITER = "haxeon.wire.MessagePackWriter";
	public static inline final MESSAGE_PACK_COMPARE_UTF8 = "haxeon.wire.MessagePackWriter.compareUtf8";
	public static inline final MESSAGE_PACK_READER = "haxeon.wire.MessagePackReader";
	public static inline final JSON_WIRE_ENCODE = "haxeon.wire.JsonWire.encode";
	public static inline final JSON_WIRE_DECODE = "haxeon.wire.JsonWire.decode";
	public static inline final JSON_WIRE_WRITER = "haxeon.wire.JsonWireWriter";
	public static inline final JSON_WIRE_READER = "haxeon.wire.JsonWireReader";
	public static inline final WIRE_FAILURE_SETTLE = "haxeon.wire.WireFailure.settle";
	public static inline final WIRE_FAILURE_DECODING = "haxeon.wire.WireFailure.decoding";
	public static inline final RPC_CONNECTION = "haxeon.rpc.RpcConnection";
	public static inline final RPC_SERVE = "haxeon.rpc.RpcConnection.serve";
	public static inline final RPC_OF = "haxeon.rpc.RpcConnection.of";
	public static inline final RPC_CONTEXT = "haxeon.rpc.RpcContext";
	public static inline final RPC_METHOD = "haxeon.rpc.RpcMethod";
	public static inline final RPC_METHOD_WIRE = "haxeon.rpc.RpcMethod.wire";
	public static inline final FUTURE = "haxeon.async.Future";

	/** The module the compiler rewrites with each compile's code identities. */
	public static inline final CODE_IDENTITY_TABLE = "haxeon.build.CodeIdentityTable";

	/** The package of the modules a Wasm host calls into. */
	public static inline final WASM_HOST_PACKAGE = "haxeon.wasm.";

	public static inline final WASM_HOST_ERROR = "haxeon.wasm.HostError";

	/**
	 * The functions the compiler expands at each call. The standard library declares each as an `extern` without a body or
	 * a native binding, so it has a signature and documentation but no function value; the typer checks both directions.
	 */
	static final intrinsics:Map<String, Bool> = [
		for (name in [
			STD_IS_OF_TYPE,
			STD_IS_EXACT_TYPE,
			STD_DOWNCAST,
			EQUALITY_EQUALS,
			EQUALITY_SAME_FOR_CHANGE,
			HASHING_HASH,
			HASHING_KEY_EQUALS,
			DIFF_COPY,
			DIFF_MASK,
			DIFF_APPLY,
			DIFF_BIT,
			DIFF_ALL,
			DIFF_FINGERPRINT,
			JSON_WIRE_ENCODE,
			JSON_WIRE_DECODE,
			MESSAGE_PACK_ENCODE,
			MESSAGE_PACK_DECODE,
			RPC_METHOD_WIRE,
			RPC_SERVE,
			RPC_OF
		])
			name => true
	];

	/** Whether the function `name` (`haxeon.Diff.copy`) is one the compiler expands at each call. */
	public static function isIntrinsic(name:String):Bool
		return intrinsics.exists(name);

	/** The intrinsics the type `owner` declares, by member name. */
	public static function intrinsicsOf(owner:String):Array<String>
		return [
			for (name in intrinsics.keys())
				if (name.length > owner.length + 1 && StringTools.startsWith(name, owner)
				&& StringTools.fastCodeAt(name, owner.length) == ".".code
				&& name.indexOf(".", owner.length + 1) < 0) name.substr(owner.length + 1)
		];

	/**
	 * Whether `callee`, a call's name as written, names the function `declaration`: in full, or as `Type.member` where the
	 * module is imported.
	 */
	public static function names(callee:String, declaration:String):Bool {
		if (callee == declaration)
			return true;
		var start = declaration.length - callee.length;
		return start > 0
			&& StringTools.fastCodeAt(declaration, start - 1) == ".".code
			&& callee.indexOf(".") > 0
			&& declaration.substr(start) == callee;
	}
}
