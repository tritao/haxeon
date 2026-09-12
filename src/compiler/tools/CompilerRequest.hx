package compiler.tools;

typedef CompilerRequest = {
	final target:String;
	final defines:Array<String>;
	final output:String;
	final xmlOutput:Null<String>;
	final irOutput:Null<String>;
	final entry:String;
	final dumpFunction:Int;
	final importMemory:Bool;
	final memoryBase:Int;
	final memoryContract:Null<String>;
	final wasmMemoryStats:Bool;
	final exports:Array<String>;
	final ffiHeader:Null<String>;
	final ffiLibrary:Null<String>;
	final ffiInterfaces:Array<String>;
	final ffiProjections:Array<String>;
	final roots:Array<String>;
	final paths:Array<String>;
}
