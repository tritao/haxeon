package compiler.hl;

/** In-memory representation of one complete HashLink bytecode module. */
class HlCode {
	public static inline final VERSION = 8;

	/** Private value-ABI metadata, excluded from source methods and reflection. */
	public static inline final TYPED_METHOD_PROTOTYPE = -2;

	public var ints:Array<Int> = [];
	public var floats:Array<Float> = [];
	public var strings:Array<String> = [];
	public var types:Array<HlTypeDef> = [];
	public var globals:Array<Int> = [];
	public var natives:Array<HlNative> = [];
	public var functions:Array<HlFunction> = [];

	/** Objects the VM creates when the module loads, each stored in one global. */
	public var constants:Array<HlConstant> = [];

	public var debugSections:Array<HlDebugSection> = [];
	public var sourceSnapshots:Array<HlSourceSnapshot> = [];
	public var entryPoint:Int = 0;

	public function new() {}
}

/** A constant object: `fields` are table indices, in the object's field order (an int index, a string index, a type index or a global). */
typedef HlConstant = {final global:Int; final fields:Array<Int>;}

/** Independently versioned, length-delimited HLB debug metadata. */
/**
 * One HLB debug section. A section derived from what the module already holds (the opcode source spans, the source snapshots) is not
 * stored: `lazy` keeps only how to produce it, and `payload` encodes it on each access, so a module that is kept between builds does not
 * also keep tens of megabytes of encoded sections that the writer would encode again.
 */
final class HlDebugSection {
	public final kind:Int;
	public final version:Int;
	public final flags:Int;
	public var payload(get, never):haxe.io.Bytes;

	final stored:Null<haxe.io.Bytes>;
	final produce:Null<() -> haxe.io.Bytes>;

	function new(kind:Int, version:Int, flags:Int, stored:Null<haxe.io.Bytes>, produce:Null<() -> haxe.io.Bytes>) {
		this.kind = kind;
		this.version = version;
		this.flags = flags;
		this.stored = stored;
		this.produce = produce;
	}

	public static function of(kind:Int, version:Int, flags:Int, payload:haxe.io.Bytes):HlDebugSection
		return new HlDebugSection(kind, version, flags, payload, null);

	public static function lazy(kind:Int, version:Int, flags:Int, produce:() -> haxe.io.Bytes):HlDebugSection
		return new HlDebugSection(kind, version, flags, null, produce);

	/** Whether the section has a payload at all, without producing a derived one. */
	public function hasPayload():Bool
		return stored != null || produce != null;

	function get_payload():haxe.io.Bytes
		return stored != null ? stored : produce();
}

/** UTF-8 source contents addressed by the hash carried in debug locations. */
typedef HlSourceSnapshot = {
	final sourceHash:Int;
	final content:haxe.io.Bytes;
}

/** Stable debugger identity for a compiled function. */
typedef HlFunctionIdentity = {
	final stableId:Int;
	final functionIndex:Int;
	final qualifiedName:String;
	final displayName:String;
	final sourcePath:String;
	final start:Int;
	final end:Int;
	final line:Int;
	final flags:Int;
}

/** HashLink type-table entry whose references are indices into {@link HlCode.types}. */
enum HlTypeDef {
	Simple(kind:HlType);
	/** Four-byte nominal enum tag; cache globals are ordinary GC roots. */
	EnumTag(boxedType:Int, cacheGlobals:Array<Int>);
	Parameterized(kind:HlType, parameter:Int);
	Abstract(name:Int);
	Function(arguments:Array<Int>, result:Int);
	Object(name:Int, base:Int, global:Int, fields:Array<HlObjectField>, methods:Array<HlObjectMethod>, bindings:Array<Int>);
	Structure(name:Int, global:Int, fields:Array<HlObjectField>, methods:Array<HlObjectMethod>, bindings:Array<Int>);
	Virtual(name:Int, fields:Array<HlVirtualField>);
	Enum(name:Int, global:Int, constructors:Array<HlEnumConstructor>);
}

/** Serialized object field expressed with string- and type-table indices. */
typedef HlObjectField = {final name:Int; final type:Int;}

/** Serialized object method binding expressed with global function indices. */
typedef HlObjectMethod = {final name:Int; final functionIndex:Int; final prototype:Int;}

/** Serialized field contract in a HashLink virtual type. */
typedef HlVirtualField = {final name:Int; final type:Int;}

/** Serialized enum constructor and its payload type indices. */
typedef HlEnumConstructor = {final name:Int; final params:Array<Int>;}

/** Native binding entry in a HashLink module's global function namespace. */
typedef HlNative = {
	final library:Int;
	final name:Int;
	final type:Int;
	final functionIndex:Int;
}
