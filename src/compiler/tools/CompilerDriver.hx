package compiler.tools;

import compiler.Compiler;
import compiler.Compiler.CompileResult;
import compiler.ffi.CHeaderEmitter;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import haxe.io.Bytes;
import sys.io.File;

/** Executes one compiler request and writes its deterministic artifacts. */
class CompilerDriver {
	public static function compile(request:CompilerRequest, ?progress:String->Void):CompileResult {
		var report = progress == null ? function(message:String) {} : progress;
		report("loading " + Std.string(request.paths.length) + " sources");
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		SourceManifestLoader.load(compiler, request.roots, request.paths);
		report("compiling entry " + request.entry);
		var result = compiler.compile(request.entry, null, false);
		if (request.dumpFunction >= 0)
			dumpFunction(result, request.dumpFunction, report);
		File.saveBytes(request.output, HlWriter.encode(result.module));
		File.saveBytes(request.output + ".functions", Bytes.ofString(functionMap(result.functionIndices)));
		if (request.ffiHeader != null && request.ffiLibrary != null)
			File.saveContent(request.ffiHeader, CHeaderEmitter.emit(result.ir.natives, request.ffiLibrary));
		report("compiled " + Std.string(request.paths.length) + " source files -> " + request.output);
		return result;
	}

	static function dumpFunction(result:CompileResult, index:Int, report:String->Void):Void
		for (fn in result.module.functions)
			if (fn.functionIndex == index) {
				report('function ${fn.functionIndex} type=${fn.type} registers=${[for (register in fn.registers) Std.string(register)].join(",")}');
				for (instructionIndex in 0...fn.opcodes.length)
					report('$instructionIndex\t${Std.string(fn.opcodes[instructionIndex])}');
			}

	static function functionMap(indices:Map<String, Int>):String {
		var names = [for (name in indices.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) Std.string(indices.get(name)) + "\t" + name].join("\n") + "\n";
	}
}
