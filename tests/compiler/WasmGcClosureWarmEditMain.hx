import compiler.Compiler;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.wasm.WasmBackend;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;

/** An edit introducing another closure signature must match a fresh Wasm GC build. */
class WasmGcClosureWarmEditMain {
	static final initial = 'function main():Int { var a:Dynamic = function(x:Int):Int return x + 1; var f:Int->Int = cast a; return f(41); }';
	static final edited = 'function main():Int { var a:Dynamic = function(x:Int):Int return x + 1; var f:Int->Int = cast a; '
		+ 'var c:Dynamic = function(x:Bool):Int return x ? 1 : 0; var g:Bool->Int = cast c; return f(40) + g(true); }';

	static function compiler(inlining:Bool):Compiler {
		var result = new Compiler(null, CompilerIntrinsics.configuration());
		result.livePatching = false;
		result.addStandardLibrarySourceRoot("stdlib");
		result.configure("gc-closure-warm-" + inlining, "gc-closure-warm",
			CompilerDriver.targetDefines("wasm-gc").concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		return result;
	}

	static function main():Void {
		var previous = Sys.getEnv("HAXEON_CHECK_REUSE");
		Sys.putEnv("HAXEON_CHECK_REUSE", "1");
		try {
			for (inlining in [false, true]) {
				var warm = compiler(inlining);
				warm.update("Main.hx", initial);
				warm.compile("Main");
				warm.update("Main.hx", edited);
				var warmIr = warm.compile("Main").ir;
				var cold = compiler(inlining);
				cold.update("Main.hx", edited);
				var coldIr = cold.compile("Main").ir;
				var options:compiler.backend.Backend.BackendOptions = {target: WasmGc, debugNames: true};
				var warmBytes = new WasmBackend().compile(warmIr, options).bytes;
				var coldBytes = new WasmBackend().compile(coldIr, options).bytes;
				if (warmBytes.compare(coldBytes) != 0)
					throw 'Wasm GC warm closure signature differs from cold, inline=$inlining';
				Sys.println('PASS: Wasm GC new closure signature warm equals cold, inline=$inlining');
			}
		} catch (error:Dynamic) {
			Sys.putEnv("HAXEON_CHECK_REUSE", previous);
			throw error;
		}
		Sys.putEnv("HAXEON_CHECK_REUSE", previous);
	}
}
