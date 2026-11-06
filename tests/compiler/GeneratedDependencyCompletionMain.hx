import compiler.Compiler;
import compiler.ir.IrInterpreter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class GeneratedDependencyCompletionMain {
	static function main():Void {
		var source = File.getContent("tests/programs/enum-generated-dependencies.hx");
		for (inlineEnabled in [false, true]) {
			var compiler = new Compiler(null, CompilerIntrinsics.configuration());
			compiler.addSourceRoot("stdlib");
			compiler.configure("generated-dependencies", "test", ["haxeon-inline=" + (inlineEnabled ? "1" : "0")]);
			compiler.update("Main.hx", source);
			for (_ in 0...2)
				if (new IrInterpreter(compiler.compile("Main").ir).run("main") != 42)
					throw "Generated dependencies were not completed on a cold or cached build";
			compiler.update("Main.hx", StringTools.replace(source, "read() == Hashing.hash(key)", "read() != Hashing.hash(key)"));
			if (new IrInterpreter(compiler.compile("Main").ir).run("main") != 1)
				throw "Generated dependencies retained a stale enum method";
		}
		Sys.println("PASS: generated enum methods complete owners, hashes, key paths and closures across cold and incremental builds");
	}
}
