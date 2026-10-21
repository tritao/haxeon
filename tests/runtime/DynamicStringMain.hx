import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.hl.HlWriter;
import sys.io.File;

/** Use a child VM: a signal must fail the test rather than terminate the test driver. */
class DynamicStringMain {
	static function main():Void {
		var compiler = configured();
		var source = File.getContent("tests/fixtures/dynamic-string-methods/Main.hx");
		for (incremental in [false, true]) {
			compiler.update("Main.hx", incremental ? StringTools.replace(source, "return 42;", "return 43;") : source);
			var result = compiler.compile("Main");
			var path = "out/dynamic-string-methods-" + (incremental ? "incremental" : "clean") + ".hl";
			File.saveBytes(path, HlWriter.encode(result.module));
			var child = run(path), expected = incremental ? 43 : 42;
			if (child.status != expected)
				throw 'Dynamic String regression (incremental=$incremental): ${child.status}: ${child.output}';
		}
		compiler = configured();
		compiler.update("Main.hx", 'function main():Void { var object:Dynamic = {}; object.missing(); }');
		var result = compiler.compile("Main"),
			path = "out/dynamic-string-missing.hl";
		File.saveBytes(path, HlWriter.encode(result.module));
		var missing = run(path);
		if (missing.status == 0 || missing.output.indexOf("Null access") < 0)
			throw 'Missing method must raise a normal null-access error: ${missing.status}: ${missing.output}';
		Sys.println("PASS: dynamic String methods and null-call errors, clean and incremental");
	}

	static function configured():Compiler {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		return compiler;
	}

	static function run(path:String):{status:Int, output:String} {
		var child = new sys.io.Process(".tools/hashlink/hl", [path]);
		var output = child.stdout.readAll().toString() + child.stderr.readAll().toString();
		var status = child.exitCode();
		child.close();
		return {status: status, output: output};
	}
}
