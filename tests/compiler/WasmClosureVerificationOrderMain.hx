import compiler.CompileOptions;
import compiler.Compiler;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.wasm.WasmBackend;
import compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;
import sys.io.File;

/**
 * Verify each closure ABI after its adapters, cold and warm. A warm HashLink build links the functions it did not lower again; a
 * warm Wasm build builds its whole module from the edited IR, which must be the module a fresh compiler builds.
 */
class WasmClosureVerificationOrderMain {
	static function main():Void {
		var source = File.getContent("tests/programs/inline-enum-callback-escape.hx");
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true]) {
				var compiler = new Compiler(null, CompilerIntrinsics.configuration());
				compiler.livePatching = false;
				compiler.addStandardLibrarySourceRoot("stdlib");
				compiler.configure("closure-verification-" + target + inlining, "closure-verification",
					CompilerDriver.targetDefines(target));
				compiler.options = new CompileOptions({inlining: inlining, checkReuse: true});
				compiler.update("Main.hx", source);
				var initial = compiler.compile("Main"),
					edited = StringTools.replace(source, "Census.run(128) == 128", "Census.run(64) == 64");
				compiler.update("Main.hx", edited);
				var changed = compiler.compile("Main");
				if (target == "hl") {
					if (changed.metrics.linkedFunctions == 0)
						throw "Closure ordering test did not exercise fresh recomputation of linked functions";
				} else {
					var fresh = new Compiler(null, CompilerIntrinsics.configuration());
					fresh.livePatching = false;
					fresh.addStandardLibrarySourceRoot("stdlib");
					fresh.configure("closure-verification-" + target + inlining, "closure-verification",
						CompilerDriver.targetDefines(target));
					fresh.options = new CompileOptions({inlining: inlining, checkReuse: true});
					fresh.update("Main.hx", edited);
					var warmBytes = BackendArtifacts.wasm(changed.artifact).bytes;
					if (warmBytes.compare(BackendArtifacts.wasm(initial.artifact).bytes) == 0)
						throw 'The warm $target build after an edit returned the earlier module';
					if (warmBytes.compare(BackendArtifacts.wasm(fresh.compile("Main").artifact).bytes) != 0)
						throw 'The warm $target build after an edit differs from a fresh build of the edited source';
				}
				compiler.update("Main.hx", source);
				compiler.compile("Main");
				Sys.println('PASS: cold/warm closure verification and fresh recomputation on $target, inline=$inlining');
			}
		for (target in [Wasm32, WasmGc])
			rejectUnadaptedValue(target);
	}

	static function rejectUnadaptedValue(target:BackendTarget):Void {
		var name = compiler.ir.IrInlineEnumLayout.VALUE_PREFIX + "Forged",
			program = new IrProgram("main");
		program.objects = [
			{
				name: name,
				isValue: true,
				base: null,
				interfaces: [],
				methods: [],
				fields: [{name: "tag", type: I32}, {name: "scalar0", type: I32}]
			}
		];
		var builder = new IrBuilder();
		builder.returnValue(builder.toDyn(builder.valueInit(name)));
		program.functions = [new IrFunction("main", builder.arguments, Dyn, builder.blocks, Ordinary)];
		var failure:Null<String> = null;
		try
			new WasmBackend().compile(program, {target: target, debugNames: true})
		catch (error:Dynamic)
			failure = Std.string(error);
		if (failure == null || failure.indexOf("Inline value storage requires a logical Dynamic adapter") < 0)
			throw 'Wasm must still reject an unadapted payload on $target, got: $failure';
		Sys.println('PASS: $target still rejects unadapted private payload escapes');
	}
}
