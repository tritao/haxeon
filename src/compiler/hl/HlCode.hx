package compiler.hl;

import compiler.core.InternalError;

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

	/** The name of each function, by its position in `functions`: what a module of sections keys it by (`HlSectionWriter`). */
	public var functionNames:Array<String> = [];

	/** The name of each global, by index, or null for one the symbol tables name by what it belongs to (a class value). */
	public var globalNames:Array<Null<String>> = [];

	public var debugSections:Array<HlDebugSection> = [];
	public var sourceSnapshots:Array<HlSourceSnapshot> = [];
	public var entryPoint:Int = 0;

	/** The sources the functions' debug locations count from (`HlDebugLocation`): the build's, or none for a module made without. */
	public var sources:compiler.core.SourceAnchor.SourceAnchors = new compiler.core.SourceAnchor.SourceAnchors([]);

	public function new() {}
}

/** A constant object: `fields` are table indices, in the object's field order (an int index, a string index, a type index or a global). */
typedef HlConstant = {
	final global:Int;
	final fields:Array<Int>;
}

/** Independently versioned, length-delimited HLB debug metadata. */
/**
 * One HLB debug section. A section derived from what the module already holds (the opcode source spans, the source snapshots) is not
 * stored: `lazy` keeps only how to produce it, and `payload` encodes it on each access, so a module that is kept between builds does not
 * also keep tens of megabytes of encoded sections that the writer would encode again.
 */
class HlDebugSection {
	public final kind:Int;
	public final version:Int;

	/** The header flags, less HlWriter.COMPRESSED, which the writer sets when it compresses the payload. */
	public final flags:Int;

	/** The LZ4 level the writer compresses the payload at (HlLz4.FAST or HC's 1 to 12), or null to store it as it is. */
	public final compression:Null<Int>;

	public var payload(get, never):haxeon.io.SegmentedBytes;

	final stored:Null<haxeon.io.SegmentedBytes>;
	final produce:Null<Null<HlWriterCache>->haxeon.io.SegmentedBytes>;

	function new(kind:Int, version:Int, flags:Int, compression:Null<Int>, stored:Null<haxeon.io.SegmentedBytes>,
			produce:Null<Null<HlWriterCache>->haxeon.io.SegmentedBytes>) {
		this.kind = kind;
		this.version = version;
		this.flags = flags;
		this.compression = compression;
		this.stored = stored;
		this.produce = produce;
	}

	public static function of(kind:Int, version:Int, flags:Int, payload:haxe.io.Bytes, ?compression:Int):HlDebugSection
		return new HlDebugSection(kind, version, flags, compression, haxeon.io.SegmentedBytes.ofBytes(payload), null);

	/** `produce` gets the writer cache the module is being written with, if any, so it can reuse what it encoded for unchanged functions. */
	public static function lazy(kind:Int, version:Int, flags:Int, produce:Null<HlWriterCache>->haxeon.io.SegmentedBytes,
			?compression:Int):HlDebugSection
		return new HlDebugSection(kind, version, flags, compression, null, produce);

	/** Whether the section has a payload at all, without producing a derived one. */
	public function hasPayload():Bool
		return stored != null || produce != null;

	function get_payload():haxeon.io.SegmentedBytes
		return payloadFor(null);

	public function payloadFor(cache:Null<HlWriterCache>):haxeon.io.SegmentedBytes {
		if (stored != null)
			return stored;
		var encode = produce;
		if (encode == null)
			throw new InternalError("Debug section has no payload");
		return encode(cache);
	}
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

	/** HashLink's method type (HMETHOD): a function type other compilers give methods. Haxeon writes Function; it reads both. */
	Method(arguments:Array<Int>, result:Int);
	Object(name:Int, base:Int, global:Int, fields:Array<HlObjectField>, methods:Array<HlObjectMethod>,
		bindings:Array<Int>);
	Structure(name:Int, global:Int, fields:Array<HlObjectField>, methods:Array<HlObjectMethod>, bindings:Array<Int>);
	Virtual(name:Int, fields:Array<HlVirtualField>);
	Enum(name:Int, global:Int, constructors:Array<HlEnumConstructor>);
}

/** Serialized object field expressed with string- and type-table indices. */
typedef HlObjectField = {
	final name:Int;
	final type:Int;
}

/** Serialized object method binding expressed with global function indices. */
typedef HlObjectMethod = {
	final name:Int;
	final functionIndex:Int;
	final prototype:Int;
}

/** Serialized field contract in a HashLink virtual type. */
typedef HlVirtualField = {
	final name:Int;
	final type:Int;
}

/** Serialized enum constructor and its payload type indices. */
typedef HlEnumConstructor = {
	final name:Int;
	final params:Array<Int>;
}

/** Native binding entry in a HashLink module's global function namespace. */
typedef HlNative = {
	final library:Int;
	final name:Int;
	final type:Int;
	final functionIndex:Int;
}
