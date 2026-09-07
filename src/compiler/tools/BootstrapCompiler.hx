package compiler.tools;

import compiler.runtime.RuntimeNatives;
import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.Compiler.CompileResult;
import haxe.io.Bytes;
import sys.io.File;

/** Builds the compiler project from an explicit, deterministic source manifest. */
class BootstrapCompiler {
	public static function main():Void {
		var output = "bootstrap/compiler.hl",
			entry = "compiler.tools.BootstrapCompiler",
			dumpFunction = -1,
			roots:Array<String> = [],
			paths:Array<String> = [];
		for (argument in Sys.args())
			if (StringTools.startsWith(argument, "--output="))
				output = argument.substring("--output=".length, argument.length);
			else if (StringTools.startsWith(argument, "--entry="))
				entry = argument.substring("--entry=".length, argument.length);
			else if (StringTools.startsWith(argument, "--root="))
				roots.push(argument.substring("--root=".length, argument.length));
			else if (StringTools.startsWith(argument, "--dump-function=")) {
				dumpFunction = parseFunctionIndex(argument.substring("--dump-function=".length, argument.length));
			} else
				paths.push(argument);
		if (roots.length == 0)
			roots.push("src");
		if (paths.length == 0)
			throw "Bootstrap compiler requires an explicit source manifest";

		Sys.println("loading " + Std.string(paths.length) + " bootstrap sources");
		var compiler = new Compiler();
		RuntimeNatives.register(compiler);
		BootstrapSources.load(compiler, roots, paths);
		Sys.println("compiling bootstrap entry " + entry);
		var result:CompileResult;
		try {
			result = compiler.compile(entry, null, false);
		} catch (failure:CompileError) {
			var diagnostic = failure.diagnostic;
			Sys.println(diagnostic.span.file.path + ":" + Std.string(diagnostic.span.start) + ": " + diagnostic.code + ": " + diagnostic.message);
			throw failure;
		}
		Sys.println("writing bootstrap artifact " + output);
		if (dumpFunction >= 0)
			for (fn in result.module.functions)
				if (fn.functionIndex == dumpFunction) {
					Sys.println('function ${fn.functionIndex} type=${fn.type} registers=${[for (register in fn.registers) Std.string(register)].join(",")}');
					for (index in 0...fn.opcodes.length)
						Sys.println('$index\t${Std.string(fn.opcodes[index])}');
				}
		File.saveBytes(output, HlWriter.encode(result.module));
		File.saveBytes(output + ".functions", Bytes.ofString(functionMap(result.functionIndices)));
		Sys.println("compiled " + Std.string(paths.length) + " source files -> " + output);
	}

	static function parseFunctionIndex(value:String):Int {
		if (value.length == 0)
			throw "Invalid function index";
		var result = 0;
		for (index in 0...value.length) {
			var digit = value.charCodeAt(index) - 48;
			if (digit < 0 || digit > 9)
				throw "Invalid function index";
			result = result * 10 + digit;
		}
		return result;
	}

	static function functionMap(indices:Map<String, Int>):String {
		var names = [for (name in indices.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) Std.string(indices.get(name)) + "\t" + name].join("\n") + "\n";
	}
}
