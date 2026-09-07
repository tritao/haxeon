package compiler.hl;

/** In-memory representation of one complete HashLink bytecode module. */
class HlCode {
	public static inline final VERSION = 7;

	public var ints:Array<Int> = [];
	public var floats:Array<Float> = [];
	public var strings:Array<String> = [];
	public var types:Array<HlTypeDef> = [];
	public var globals:Array<Int> = [];
	public var natives:Array<HlNative> = [];
	public var functions:Array<HlFunction> = [];
	public var debugSections:Array<HlDebugSection> = [];
	public var entryPoint:Int = 0;

	public function new() {}
}

/** Independently versioned, length-delimited HLB debug metadata. */
typedef HlDebugSection = {final kind:Int; final version:Int; final flags:Int; final payload:haxe.io.Bytes;}

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
	Parameterized(kind:HlType, parameter:Int);
	Abstract(name:Int);
	Function(arguments:Array<Int>, result:Int);
	Object(name:Int, base:Int, global:Int, fields:Array<HlObjectField>, methods:Array<HlObjectMethod>, bindings:Array<Int>);
	Structure(name:Int, global:Int, fields:Array<HlObjectField>, methods:Array<HlObjectMethod>, bindings:Array<Int>);
	Virtual(fields:Array<HlVirtualField>);
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
