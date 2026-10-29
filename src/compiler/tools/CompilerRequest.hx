package compiler.tools;

typedef PackageSourceRoot = {
	final packageName:String;
	final path:String;
}

typedef CompilerRequest = {
	final target:String;
	final defines:Array<String>;
	final output:String;
	final xmlOutput:Null<String>;
	final irOutput:Null<String>;
	final entry:String;
	final dumpFunction:Int;
	final importMemory:Bool;
	final ?sharedMemory:Bool;
	final memoryBase:Int;
	final memoryContract:Null<String>;
	final wasmMemoryStats:Bool;
	final wasmGcStress:Bool;
	final wasmRuntimeNeutral:Bool;

	/**
	 * Keep the append-only function, symbol and stable-id history across requests so a running module can be
	 * patched (`haxeon run --watch --live`). Without it every compile assembles from scratch and its bytes are a
	 * function of the source alone, whatever the session compiled before.
	 */
	final live:Bool;

	/**
	 * Where `output` is published when the compile server stages it under a temporary name. A live session that starts
	 * without history resumes the module published there, not the staged copy.
	 */
	final ?publishedOutput:String;

	final exports:Array<String>;
	final ffiHeader:Null<String>;
	final ffiLibrary:Null<String>;
	final ffiInterfaces:Array<String>;
	final ffiProjections:Array<String>;
	final roots:Array<String>;
	final packageRoots:Array<PackageSourceRoot>;
	final paths:Array<String>;
}
