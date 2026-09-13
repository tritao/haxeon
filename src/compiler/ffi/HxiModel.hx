package compiler.ffi;

import compiler.Source.SourceSpan;

/** Normalized documentation attached to one HXI declaration or member. */
typedef HxiDocumentation = {
	final raw:String;
	final lines:Array<String>;
	final source:String;
	final indentedSource:String;
}

enum HxiType {
	Primitive(name:String);
	Named(name:String);
	Pointer(element:HxiType);
	Nullable(element:HxiType);
	Const(element:HxiType);
	Array(element:HxiType, length:Int);
}

typedef HxiField = {
	final name:String;
	final type:HxiType;
	final offset:Null<Int>;
	final ownership:HxiPointerOwnership;
	final lengthField:Null<String>;
	final span:SourceSpan;
}

typedef HxiParameter = {
	final name:String;
	final type:HxiType;
	final direction:HxiParameterDirection;
	final ownership:HxiPointerOwnership;

	/** The native callee keeps this callback after the call returns. */
	final retained:Bool;

	final span:SourceSpan;
}

enum HxiParameterDirection {
	In;
	InArray(countParameter:String);
	OutArray(countParameter:String);
	Out;
	InOut;
	OutBuffer(sizeParameter:String);
}

enum HxiPointerOwnership {
	Unspecified;
	Borrowed;
	Owned(releaseSymbol:String);
}

typedef HxiResultPolicy = {
	final ownership:HxiPointerOwnership;
	final length:Null<String>;
}

typedef HxiEnumValue = {
	final name:String;

	/** Signed 64-bit storage of the ABI bit pattern; unsigned values use two's-complement. */
	final value:haxe.Int64;

	final span:SourceSpan;
}

enum HxiDeclaration {
	Opaque(name:String, span:SourceSpan);
	Alias(name:String, type:HxiType, span:SourceSpan);
	Handle(name:String, representation:HxiType, span:SourceSpan);
	Constant(name:String, value:String, span:SourceSpan);
	Structure(name:String, size:Int, align:Int, fields:Array<HxiField>, span:SourceSpan);
	Enumeration(name:String, representation:HxiType, flags:Bool, values:Array<HxiEnumValue>, span:SourceSpan);
	Callback(name:String, parameters:Array<HxiParameter>, result:HxiType, callConvention:String, span:SourceSpan);
	Function(name:String, parameters:Array<HxiParameter>, result:HxiType, symbol:Null<String>, leaf:Bool, callConvention:String, resultPolicy:HxiResultPolicy,
		span:SourceSpan);
}

class HxiInterface {
	public final name:String;
	public final target:String;
	public final library:Null<String>;

	/** Other HXI interfaces whose declarations are visible to this interface.
	 *
	 * Dependencies are a composition boundary, not another native library
	 * load.  Their declarations are projected by the owning interface and are
	 * omitted from this interface's generated source/native list.
	 */
	public final dependencies:Array<String>;

	public final declarations:Array<HxiDeclaration>;

	/** Documentation keyed by declaration name or `type.member` name. */
	public final documentation:Map<String, HxiDocumentation>;

	public final span:SourceSpan;

	public function new(name:String, target:String, library:Null<String>, dependencies:Array<String>, declarations:Array<HxiDeclaration>, span:SourceSpan,
			?documentation:Map<String, HxiDocumentation>) {
		this.name = name;
		this.target = target;
		this.library = library;
		this.dependencies = dependencies;
		this.declarations = declarations;
		this.documentation = documentation == null ? [] : documentation;
		this.span = span;
	}
}
