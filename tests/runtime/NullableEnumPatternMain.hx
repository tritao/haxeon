import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.backend.wasm.WasmBackend;
import compiler.backend.Backend.BackendTarget;
import sys.io.File;

class NullableEnumPatternMain {
	static function main():Void {
		var compiler = new Compiler();
		var source = File.getContent("tests/programs/nullable-enum-array-pattern.hx");
		for (incremental in [false, true]) {
			compiler.update("Main.hx", incremental ? StringTools.replace(source, "return 42;", "return 43;") : source);
			var result = compiler.compile("Main"),
				build = incremental ? "incremental" : "clean";
			var path = 'out/nullable-enum-pattern-$build.hl';
			File.saveBytes(path, HlWriter.encode(result.module));
			var child = new sys.io.Process(".tools/hashlink/hl", [path]);
			var output = child.stdout.readAll().toString() + child.stderr.readAll().toString(),
				code = child.exitCode();
			child.close();
			if (code != (incremental ? 43 : 42))
				throw 'Nullable enum patterns ($build) returned $code: $output';
			for (target in [Wasm32, WasmGc])
				File.saveBytes('out/nullable-enum-pattern-$target-$build.wasm', new WasmBackend().compile(result.ir, {target: target, debugNames: true})
					.bytes);
		}
		Sys.println("PASS: nullable tuple and payload enum patterns, clean and incremental");
	}
}
