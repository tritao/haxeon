import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.wasm.WasmBackend;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import sys.io.File;

/** Verify each closure ABI after its adapters, including the session's auxiliary HashLink assembly. */
class WasmClosureVerificationOrderMain {
	static function main():Void {
		Sys.putEnv("HAXEON_CHECK_REUSE", "1");
		var source = File.getContent("tests/programs/inline-enum-callback-escape.hx");
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true]) {
				var compiler = new Compiler(null, CompilerIntrinsics.configuration());
				compiler.livePatching = false;
				compiler.addStandardLibrarySourceRoot("stdlib");
				compiler.configure("closure-verification-" + target + inlining, "closure-verification",
					CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
				compiler.update("Main.hx", source);
				compiler.compile("Main");
				compiler.update("Main.hx", StringTools.replace(source, "Census.run(128) == 128", "Census.run(64) == 64"));
				var changed = compiler.compile("Main");
				if (changed.metrics.linkedFunctions == 0)
					throw "Closure ordering test did not exercise fresh recomputation of linked functions";
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
		builder.returnValue(builder.toDyn(builder.newObject(name)));
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
