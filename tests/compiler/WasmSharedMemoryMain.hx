import compiler.tools.CompilerArguments;
import compiler.backend.wasm.WasmModule;
import compiler.backend.wasm.WasmEncoder;
import sys.io.File;

/** ABI regression: shared imports need a maximum and explicit admission. */
class WasmSharedMemoryMain {
	static function main():Void {
		var request = CompilerArguments.parse([
			"--target=wasm32",
			"--wasm-import-memory",
			"--wasm-shared-memory",
			"--wasm-memory-contract=contract.json",
			"Main.hx"
		]);
		if (request.sharedMemory != true)
			throw "Shared-memory option was lost";
		for (flags in [[], ["--wasm-import-memory"], ["--wasm-memory-contract=contract.json"]]) {
			var rejected = false;
			try
				CompilerArguments.parse(["--target=wasm32", "--wasm-shared-memory", "Main.hx"].concat(flags))
			catch (error:Dynamic)
				rejected = true;
			if (!rejected)
				throw "Unbounded/unimported shared memory was admitted";
		}
		var module = new WasmModule();
		module.importMemory = true;
		module.sharedMemory = true;
		module.memoryMin = 1;
		module.memoryMax = 2;
		File.saveBytes(Sys.args()[0], WasmEncoder.encode(module));
		module.sharedMemory = false;
		module.memoryMax = null;
		File.saveBytes(Sys.args()[1], WasmEncoder.encode(module));
		module.sharedMemory = true;
		var rejected = false;
		try
			WasmEncoder.encode(module)
		catch (error:Dynamic)
			rejected = true;
		if (!rejected)
			throw "Shared memory without maximum was encoded";
		Sys.println("PASS: shared memory options and encoding");
	}
}
