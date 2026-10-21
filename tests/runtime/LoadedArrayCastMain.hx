import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import runtime.Runtime;
import sys.io.File;

/** Native arrays and module-local arrays must agree on String storage without copying. */
class LoadedArrayCastMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		var source = File.getContent("tests/fixtures/loaded-array-cast/Main.hx");
		for (incremental in [false, true]) {
			compiler.update("Main.hx", incremental ? StringTools.replace(source, "return 42;", "return 43;") : source);
			var result = compiler.compile("Main"),
				bytes = HlWriter.encode(result.module);
			var expected = incremental ? 43 : 42;
			var path = "out/loaded-array-cast-" + (incremental ? "incremental" : "clean") + ".hl";
			File.saveBytes(path, bytes);
			var child = new sys.io.Process(".tools/hashlink/hl", [path]);
			var output = child.stdout.readAll().toString() + child.stderr.readAll().toString();
			var code = child.exitCode();
			child.close();
			if (code != expected)
				throw 'Standalone array cast returned $code: $output';
			// Repeated loads exercise independent module descriptors in one host.
			for (_ in 0...2) {
				var live = Runtime.load(bytes, result.runtimeIdentity);
				var code = Runtime.callInt(live, result.functionIds.get("main"));
				Runtime.dispose(live);
				if (code != expected)
					throw 'Loaded array cast returned $code (incremental=$incremental)';
			}
		}
		Sys.println("PASS: loaded String array casts and concatenation, clean and incremental");
	}
}
