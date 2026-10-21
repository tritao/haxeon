import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.backend.wasm.WasmBackend;
import compiler.backend.Backend.BackendTarget;
import sys.io.File;

class WasmDynamicStringMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.configure("wasm-dynamic-string", "wasm-dynamic-string", ["wasm", "target=wasm32"]);
		compiler.addSourceRoot("stdlib");
		var source = File.getContent("tests/fixtures/dynamic-string-methods/Main.hx");
		for (incremental in [false, true]) {
			compiler.update("Main.hx", incremental ? StringTools.replace(source, "return 42;", "return 43;") : source);
			var result = compiler.compile("Main");
			for (target in [Wasm32, WasmGc]) {
				File.saveBytes('out/dynamic-string-$target-' + (incremental ? "incremental" : "clean") + ".wasm",
					new WasmBackend().compile(result.ir, {target: target, debugNames: true}).bytes);
				if (target == Wasm32)
					File.saveBytes('out/dynamic-string-Wasm32-stress-' + (incremental ? "incremental" : "clean") + ".wasm",
						new WasmBackend().compile(result.ir, {
							target: target,
							debugNames: true,
							wasmGcStress: true
						}).bytes);
			}
		}
	}
}
