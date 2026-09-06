package compiler.tools;

import compiler.RuntimeAbi;
import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.Compiler.CompileResult;
import sys.io.File;

/** Builds the compiler project from an explicit, deterministic source manifest. */
class BootstrapCompiler {
	public static function main():Void {
		var output = "bootstrap/compiler.hl",
			entry = "compiler.tools.BootstrapCompiler",
			roots:Array<String> = [],
			paths:Array<String> = [];
		for (argument in Sys.args())
			if (StringTools.startsWith(argument, "--output="))
				output = argument.substring("--output=".length, argument.length);
			else if (StringTools.startsWith(argument, "--entry="))
				entry = argument.substring("--entry=".length, argument.length);
			else if (StringTools.startsWith(argument, "--root="))
				roots.push(argument.substring("--root=".length, argument.length));
			else
				paths.push(argument);
		if (roots.length == 0)
			roots.push("src");
		if (paths.length == 0)
			throw "Bootstrap compiler requires an explicit source manifest";

		Sys.println("loading " + Std.string(paths.length) + " bootstrap sources");
		var compiler = new Compiler();
		RuntimeAbi.register(compiler);
		BootstrapSources.load(compiler, roots, paths);
		Sys.println("compiling bootstrap entry " + entry);
		var result:CompileResult;
		try {
			result = compiler.compile(entry);
		} catch (failure:CompileError) {
			var diagnostic = failure.diagnostic;
			Sys.println(diagnostic.span.file.path + ":" + Std.string(diagnostic.span.start) + ": " + diagnostic.code + ": " + diagnostic.message);
			throw failure;
		}
		Sys.println("writing bootstrap artifact " + output);
		File.saveBytes(output, HlWriter.encode(result.module));
		Sys.println("compiled " + Std.string(paths.length) + " source files -> " + output);
	}
}
