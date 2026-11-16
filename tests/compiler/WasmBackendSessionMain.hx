import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;

using compiler.compilation.BackendArtifact.BackendArtifacts;

/**
 * A Wasm build is the Wasm session backend's: it builds the module during the build and runs no HashLink assembly, a warm edit
 * builds the module a cold build does, a build that reuses its IR keeps the module it was built with, and a build the Wasm
 * backend rejects rolls back with the candidate, module cache included.
 */
class WasmBackendSessionMain {
	static final initial =
		"function main():Int { var values = [1, 2, 3]; var total = 0; for (value in values) total += value; return total + 36; }";
	static final edited =
		"function main():Int { var values = [1, 2, 3, 4]; var total = 0; for (value in values) total += value; return total + 32; }";

	static function compiler(target:String):Compiler {
		var result = new Compiler(null, CompilerIntrinsics.configuration());
		result.livePatching = false;
		result.developmentMetadata = false;
		result.addStandardLibrarySourceRoot("stdlib");
		result.configure("wasm-session-" + target, "wasm-session", CompilerDriver.targetDefines(target));
		return result;
	}

	static function expect(condition:Bool, message:String):Void
		if (!condition)
			throw message;

	static function main():Void {
		for (target in ["wasm32", "wasm-gc"]) {
			var warm = compiler(target);
			expect(warm.backend.hashLink() == null && warm.backend.wasm() != null,
				'$target: the session backend is not the Wasm one');
			warm.update("Main.hx", initial);
			var first = warm.compile("Main");
			var phases = [for (phase in first.metrics.allocationPhases) phase.name];
			expect(phases.indexOf("wasm-module") >= 0 && phases.indexOf("backend-assembly") < 0
				&& phases.indexOf("patch") < 0,
				'$target: a Wasm build ran HashLink assembly (phases ${phases.join(",")})');
			expect(first.metrics.backendLoweringMs == 0 && first.metrics.linkedFunctions == 0,
				'$target: a Wasm build reports HashLink lowering');
			first.artifact.wasm();

			warm.update("Main.hx", edited);
			var second = warm.compile("Main"),
				secondBytes = second.artifact.wasm().bytes;
			var cold = compiler(target);
			cold.update("Main.hx", edited);
			expect(cold.compile("Main").artifact.wasm().bytes.compare(secondBytes) == 0,
				'$target: a warm edit built another module than a cold build');

			// Equal pipeline inputs reuse the IR, and the module built from it. Registering a root again makes the session build
			// rather than return its last result.
			warm.addStandardLibrarySourceRoot("stdlib");
			var third = warm.compile("Main");
			expect(third.metrics.reuse == "ir+module",
				'$target: an unchanged program was not reused (${third.metrics.reuse})');
			expect(third.artifact.wasm().bytes == secondBytes, '$target: a reused build built its module again');

			// A build the backend rejects leaves the session as the last successful build left it.
			warm.update("Main.hx", initial);
			warm.backendOptions = {
				target: target == "wasm32" ? Wasm32 : WasmGc,
				debugNames: true,
				developmentMetadata: false,
				memoryBase: 4
			};
			var rejected = false;
			try
				warm.compile("Main")
			catch (error:Dynamic)
				rejected = Std.string(error).indexOf("8-byte-aligned") >= 0;
			expect(rejected, '$target: a misaligned memory base was not rejected by the Wasm backend');
			warm.backendOptions = null;
			warm.update("Main.hx", edited);
			var recovered = warm.compile("Main");
			expect(recovered.metrics.reuse == "ir+module" && recovered.artifact.wasm().bytes == secondBytes,
				'$target: the failed build did not roll the Wasm session back (${recovered.metrics.reuse})');
			Sys.println('PASS: Wasm session backend builds, reuses and rolls back $target modules');
		}
		sessionRebuilds();
	}

	/** A compile session (the compile server's) builds a Wasm module again after an edit, as it does a HashLink one. */
	static function sessionRebuilds():Void {
		var directory = (Sys.getEnv("TMPDIR") == null ? "out" : Sys.getEnv("TMPDIR")) + "/wasm-backend-session";
		if (!FileSystem.exists(directory))
			FileSystem.createDirectory(directory);
		var source = directory + "/Main.hx", output = directory + "/main.wasm";
		for (target in ["wasm32", "wasm-gc"]) {
			var request = CompilerArguments.parse([
				"--target=" + target,
				"--entry=Main",
				"--root=" + directory,
				"--output=" + output,
				source
			]);
			var session = new CompilerSession();
			File.saveContent(source, initial);
			CompilerDriver.compile(request, null, session);
			File.saveContent(source, edited);
			CompilerDriver.compile(request, null, session);
			var warmBytes = File.getBytes(output);
			CompilerDriver.compile(request, null, new CompilerSession());
			expect(File.getBytes(output).compare(warmBytes) == 0,
				'$target: a warm session build differs from a cold one');
			Sys.println('PASS: a compile session rebuilds $target after an edit');
		}
	}
}
