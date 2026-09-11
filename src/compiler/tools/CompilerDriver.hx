package compiler.tools;

import compiler.Compiler;
import compiler.Compiler.CompileResult;
import compiler.ffi.CHeaderEmitter;
import compiler.runtime.CompilerIntrinsics;
import compiler.backend.Backend;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.hl.HlBackend;
import compiler.backend.wasm.WasmBackend;
import compiler.ir.Ir.IrProgram;
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
		var backend:Backend = request.target == "wasm32" ? new WasmBackend() : new HlBackend(),
			backendResult = backend.compile(result.ir, {target: request.target == "wasm32" ? Wasm32 : HashLink, debugNames: true});
		File.saveBytes(request.output, backendResult.bytes);
		if (request.target == "wasm32")
			File.saveContent(request.output + ".functions", wasmFunctionMap(result.ir));
		if (request.target != "wasm32")
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

	static function wasmFunctionMap(program:IrProgram):String {
		var index = 0, lines:Array<String> = [];
		for (fn in program.functions) {
			if (fn.name == "__entry")
				continue;
			lines.push(Std.string(index++) + "\t" + fn.name);
		}
		return lines.join("\n") + (lines.length == 0 ? "" : "\n");
	}
}
