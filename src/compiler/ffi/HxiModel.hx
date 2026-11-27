package compiler.ffi;

import compiler.core.Source.SourceSpan;

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
	final ownership:HxiOwnership;
	final handleDisposition:HxiHandleDisposition;
	final lengthField:Null<String>;
	final structSize:Bool;
	final metadata:Map<String, Array<String>>;
	final span:SourceSpan;
}

typedef HxiParameter = {
	final name:String;
	final type:HxiType;
	final direction:HxiParameterDirection;
	final ownership:HxiOwnership;
	final handleDisposition:HxiHandleDisposition;

	/** The native callee keeps this callback after the call returns. */
	final retained:Bool;

	final metadata:Map<String, Array<String>>;

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

enum HxiOwnership {
	Unspecified;
	Borrowed;
	Owned(releaseSymbol:String);
}

/** Whether a value handle passed or returned by value transfers its disposition. */
enum HxiHandleDisposition {
	Unspecified;
	Owned;
}

typedef HxiResultPolicy = {
	final ownership:HxiOwnership;
	final handleDisposition:HxiHandleDisposition;
	final length:Null<String>;

	/** The size_t element-count function of a borrowed pointer result read as a NativeSpan. */
	final span:Null<String>;

	final metadata:Map<String, Array<String>>;
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
	Handle(name:String, representation:HxiType, destroySymbol:Null<String>, span:SourceSpan);
	Constant(name:String, value:String, span:SourceSpan);
	/** A C record; its size, alignment and field offsets follow from the fields for each ABI (`HxiAbi.structLayout`). */
	Structure(name:String, fields:Array<HxiField>, span:SourceSpan);
	Enumeration(name:String, representation:HxiType, flags:Bool, values:Array<HxiEnumValue>, span:SourceSpan);
	Callback(name:String, parameters:Array<HxiParameter>, result:HxiType, callConvention:String, span:SourceSpan);
	Function(name:String, parameters:Array<HxiParameter>, result:HxiType, symbol:Null<String>, leaf:Bool,
		callConvention:String, resultPolicy:HxiResultPolicy,
		span:SourceSpan);
}

class HxiInterface {
	/** The name an interface imported from `header` gets when its manifest names none: the header's file name. */
	public static function defaultName(header:String):String
		return StringTools.replace(StringTools.replace(header, "\\", "/").split("/").pop(), ".", "_");

	/** The target an interface declares when it is valid on both portable profiles, laid out for the one a build uses. */
	public static inline final PORTABLE = "portable";

	public final name:String;

	/** The C ABI the declarations are laid out for: a target triple, a portable profile, or `PORTABLE` until `resolve`. */
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

	public function new(name:String, target:String, library:Null<String>, dependencies:Array<String>,
			declarations:Array<HxiDeclaration>, span:SourceSpan,
			?documentation:Map<String, HxiDocumentation>) {
		this.name = name;
		this.target = target;
		this.library = library;
		this.dependencies = dependencies;
		this.declarations = declarations;
		this.documentation = documentation == null ? [] : documentation;
		this.span = span;
	}

	/** This interface laid out for `profile` when it is portable; otherwise this interface, which names its own target. */
	public function resolve(profile:String):HxiInterface
		return target != PORTABLE ? this : new HxiInterface(name, profile, library, dependencies, declarations, span,
			documentation);
}
