package compiler.ffi;

import compiler.Source.SourceSpan;

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
	final span:SourceSpan;
}

typedef HxiParameter = {
	final name:String;
	final type:HxiType;
	final span:SourceSpan;
}

enum HxiDeclaration {
	Opaque(name:String, span:SourceSpan);
	Alias(name:String, type:HxiType, span:SourceSpan);
	Constant(name:String, value:String, span:SourceSpan);
	Structure(name:String, size:Int, align:Int, fields:Array<HxiField>, span:SourceSpan);
	Function(name:String, parameters:Array<HxiParameter>, result:HxiType, symbol:Null<String>, leaf:Bool, span:SourceSpan);
}

class HxiInterface {
	public final name:String;
	public final target:String;
	public final library:Null<String>;
	public final declarations:Array<HxiDeclaration>;
	public final span:SourceSpan;

	public function new(name:String, target:String, library:Null<String>, declarations:Array<HxiDeclaration>, span:SourceSpan) {
		this.name = name;
		this.target = target;
		this.library = library;
		this.declarations = declarations;
		this.span = span;
	}
}
