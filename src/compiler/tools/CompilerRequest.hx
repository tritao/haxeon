package compiler.tools;

typedef CompilerRequest = {
	final output:String;
	final entry:String;
	final dumpFunction:Int;
	final ffiHeader:Null<String>;
	final ffiLibrary:Null<String>;
	final ffiInterfaces:Array<String>;
	final roots:Array<String>;
	final paths:Array<String>;
}
