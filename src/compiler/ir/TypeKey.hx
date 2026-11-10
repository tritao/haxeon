package compiler.ir;

import compiler.ir.Ir.IrType;

/**
 * What a generated helper is for, in the IR's own terms: the canonical text of an IR type. The only way to make one is `of`, so a key
 * derived from a function name or any other string does not compile; the walk that keeps helpers alive matches them against the types
 * the program creates, and a name-derived key would never match. Two source types that lower to one IR type (erased generics) get one
 * key, which only makes the walk keep more, never less.
 *
 * The text is written here, not taken from `Std.string`, so it does not change with the Haxe version, and it never contains a NUL
 * (HashLink compares map keys as C strings).
 */
abstract TypeKey(String) {
	inline function new(text:String)
		this = text;

	public static function of(type:IrType):TypeKey
		return new TypeKey(text(type));

	/** Only for reading a persisted function back (`IrFunctionStateCodec`): the text a key wrote. */
	public static inline function fromPersisted(text:String):TypeKey
		return new TypeKey(text);

	public inline function toString():String
		return this;

	/** Whether this is the key of an enum type. */
	public inline function isEnum():Bool
		return StringTools.startsWith(this, "enum:");

	static function text(type:IrType):String
		return switch type {
			case Void: "void";
			case I32: "i32";
			case I64: "i64";
			case Bool: "bool";
			case F32: "f32";
			case F64: "f64";
			case Bytes: "bytes";
			case RawPtr: "rawptr";
			case ManagedBytes: "managedbytes";
			case Dyn: "dyn";
			case TypeRef: "typeref";
			case Nullable(element): "nullable(" + text(element) + ")";
			case Array(element): "array(" + text(element) + ")";
			case Iterator(element): "iterator(" + text(element) + ")";
			case Enum(name): "enum:" + name;
			case Obj(name): "obj:" + name;
			case Abstract(name): "abstract:" + name;
			case Virtual(name): "virtual:" + name;
			case Function(arguments, result): "fn(" + [for (argument in arguments) text(argument)].join(",") + ")->" + text(result);
		};
}
