package compiler.ffi;

import compiler.Source.SourceSpan;

/** Source-language type retained until the C++ ABI lowering boundary. */
enum CxxType {
	CxxVoid;
	CxxPrimitive(name:String);
	CxxNamed(name:String);
	CxxConst(element:CxxType);
	CxxPointer(element:CxxType);
	CxxReference(element:CxxType);
	CxxRValueReference(element:CxxType);

	/** std::string_view; lowered through a generated (const char *, size_t) adapter. */
	CxxStringView;

	/** A supported read-only byte std::span; lowered through a generated (const byte *, size_t) adapter. */
	CxxByteSpan(element:CxxSpanElement);

	CxxUnsupported(raw:String, reason:String);
}

enum CxxSpanElement {
	CxxStdByte;
	CxxUInt8;
}

typedef CxxParameter = {
	final name:String;
	final type:CxxType;
	final span:SourceSpan;
}

typedef CxxField = {
	final name:String;
	final type:CxxType;
	final offset:Null<Int>;
	final bitfield:Bool;
	final span:SourceSpan;
}

typedef CxxBase = {
	final name:String;
	final access:String;
	final isVirtual:Bool;
	final span:SourceSpan;
}

typedef CxxVirtualMethodAbi = {
	final vtableIndex:Int;
	final thisAdjustment:Int;
}

typedef CxxEnumValue = {
	final name:String;
	final value:String;
	final span:SourceSpan;
}

class CxxFunction {
	public final name:String;
	public final qualifiedName:String;
	public final symbol:String;
	public final parameters:Array<CxxParameter>;
	public final result:CxxType;
	public final isNoexcept:Bool;
	public final span:SourceSpan;
	public var loweredName:Null<String>;
	public var thunkSymbol:Null<String>;

	public function new(name:String, qualifiedName:String, symbol:String, parameters:Array<CxxParameter>, result:CxxType, isNoexcept:Bool, span:SourceSpan) {
		this.name = name;
		this.qualifiedName = qualifiedName;
		this.symbol = symbol;
		this.parameters = parameters;
		this.result = result;
		this.isNoexcept = isNoexcept;
		this.span = span;
		this.thunkSymbol = null;
	}
}

class CxxMethod {
	public final owner:String;
	public final name:String;
	public final qualifiedName:String;
	public final symbol:String;
	public final access:String;
	public final isStatic:Bool;
	public final isConst:Bool;
	public final isNoexcept:Bool;
	public final isVirtual:Bool;
	public final isConstructor:Bool;
	public final isDestructor:Bool;
	public final parameters:Array<CxxParameter>;
	public final result:CxxType;
	public final span:SourceSpan;
	public var loweredName:Null<String>;
	public var virtualAbi:Null<CxxVirtualMethodAbi>;
	public var thunkSymbol:Null<String>;

	public function new(owner:String, name:String, qualifiedName:String, symbol:String, access:String, isStatic:Bool, isConst:Bool, isNoexcept:Bool,
			isVirtual:Bool, parameters:Array<CxxParameter>, result:CxxType, span:SourceSpan, isConstructor:Bool = false, isDestructor:Bool = false) {
		this.owner = owner;
		this.name = name;
		this.qualifiedName = qualifiedName;
		this.symbol = symbol;
		this.access = access;
		this.isStatic = isStatic;
		this.isConst = isConst;
		this.isNoexcept = isNoexcept;
		this.isVirtual = isVirtual;
		this.isConstructor = isConstructor;
		this.isDestructor = isDestructor;
		this.parameters = parameters;
		this.result = result;
		this.span = span;
		this.virtualAbi = null;
		this.thunkSymbol = null;
	}
}

class CxxRecord {
	public final name:String;
	public final qualifiedName:String;
	public final tagUsed:String;
	public final completeDefinition:Bool;
	public final isAbstract:Bool;
	public final size:Int;
	public final align:Int;
	public final isStandardLayout:Bool;
	public final isTriviallyCopyable:Bool;
	public final hasVirtualMembers:Bool;
	public final bases:Array<CxxBase>;
	public final fields:Array<CxxField>;
	public final methods:Array<CxxMethod>;
	public final span:SourceSpan;

	public function new(name:String, qualifiedName:String, tagUsed:String, completeDefinition:Bool, isAbstract:Bool, size:Int, align:Int,
			isStandardLayout:Bool, isTriviallyCopyable:Bool, hasVirtualMembers:Bool, bases:Array<CxxBase>, fields:Array<CxxField>, methods:Array<CxxMethod>,
			span:SourceSpan) {
		this.name = name;
		this.qualifiedName = qualifiedName;
		this.tagUsed = tagUsed;
		this.completeDefinition = completeDefinition;
		this.isAbstract = isAbstract;
		this.size = size;
		this.align = align;
		this.isStandardLayout = isStandardLayout;
		this.isTriviallyCopyable = isTriviallyCopyable;
		this.hasVirtualMembers = hasVirtualMembers;
		this.bases = bases;
		this.fields = fields;
		this.methods = methods;
		this.span = span;
	}
}

class CxxEnum {
	public final name:String;
	public final qualifiedName:String;
	public final scoped:Bool;
	public final underlying:CxxType;
	public final values:Array<CxxEnumValue>;
	public final span:SourceSpan;

	public function new(name:String, qualifiedName:String, scoped:Bool, underlying:CxxType, values:Array<CxxEnumValue>, span:SourceSpan) {
		this.name = name;
		this.qualifiedName = qualifiedName;
		this.scoped = scoped;
		this.underlying = underlying;
		this.values = values;
		this.span = span;
	}
}

class CxxAlias {
	public final name:String;
	public final qualifiedName:String;
	public final target:CxxType;
	public final span:SourceSpan;

	public function new(name:String, qualifiedName:String, target:CxxType, span:SourceSpan) {
		this.name = name;
		this.qualifiedName = qualifiedName;
		this.target = target;
		this.span = span;
	}
}

/** C++ source semantics. HXI is produced only by CxxAbiLowerer. */
class CxxModel {
	public final target:String;
	public final header:String;
	public final span:SourceSpan;
	public final records:Array<CxxRecord>;
	public final enums:Array<CxxEnum>;
	public final aliases:Array<CxxAlias>;
	public final functions:Array<CxxFunction>;

	public function new(target:String, header:String, span:SourceSpan, records:Array<CxxRecord>, enums:Array<CxxEnum>, aliases:Array<CxxAlias>,
			functions:Array<CxxFunction>) {
		this.target = target;
		this.header = header;
		this.span = span;
		this.records = records;
		this.enums = enums;
		this.aliases = aliases;
		this.functions = functions;
	}
}
