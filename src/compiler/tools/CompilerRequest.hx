package compiler.tools;

typedef CompilerRequest = {
	final target:String;
	final output:String;
	final xmlOutput:Null<String>;
	final irOutput:Null<String>;
	final entry:String;
	final dumpFunction:Int;
	final ffiHeader:Null<String>;
	final ffiLibrary:Null<String>;
	final ffiInterfaces:Array<String>;
	final ffiProjections:Array<String>;
	final roots:Array<String>;
	final paths:Array<String>;
}
