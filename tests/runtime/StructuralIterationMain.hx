import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.hl.HlWriter;
import runtime.Runtime;
import sys.io.File;
import compiler.backend.wasm.WasmBackend;
import compiler.backend.Backend.BackendTarget;

class StructuralIterationMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.update("Lambda.hx", File.getContent("stdlib/Lambda.hx"));
		var source = File.getContent("tests/programs/structural-iteration.hx");
		var collectionStart = source.indexOf("class Collection"),
			functionsStart = source.indexOf("function sum");
		var counter = source.substring(0, collectionStart);
		compiler.update("Counter.hx", counter);
		compiler.update("Collection.hx", source.substring(collectionStart, functionsStart));
		compiler.update("Main.hx", "import Counter; import Collection;\n" + source.substr(functionsStart));
		for (incremental in [false, true]) {
			if (incremental)
				compiler.update("Counter.hx", StringTools.replace(counter, "return 4;", "return 5;"));
			var result = compiler.compile("Main");
			var checked = 0;
			for (fn in result.ir.functions)
				if (fn.name.indexOf("concreteLoop") >= 0 || fn.name.indexOf("arrayHelper") >= 0) {
					checked++;
					for (block in fn.blocks)
						for (instruction in block.instructions)
							switch instruction.value {
								case NewObject(_, _), IteratorNew(_, _), InstanceClosure(_, _, _):
									throw 'Concrete iteration allocated in ${fn.name}';
								default:
							}
				}
			if (checked < 2)
				throw "Allocation regression checks did not inspect both concrete loops: " + [for (fn in result.ir.functions) fn.name].join(", ");
			for (target in [Wasm32, WasmGc]) {
				File.saveBytes('out/structural-iteration-$target-' + (incremental ? "incremental" : "clean") + ".wasm",
					new WasmBackend().compile(result.ir, {target: target, debugNames: true}).bytes);
			}
			var live = Runtime.load(HlWriter.encode(result.module), result.runtimeIdentity);
			var value = Runtime.callInt(live, result.functionIds.get("main"));
			Runtime.dispose(live);
			var expected = incremental ? 43 : 42;
			if (value != expected)
				throw 'Expected $expected, got $value (incremental=$incremental)';
		}
		for (invalid in [
			'class Bad { public function new() {} public function hasNext():Int return 1; public function next():Int return 0; } function main():Int { for (x in new Bad()) {} return 0; }',
			'class Bad { public function new() {} public function hasNext(required:Int):Bool return false; public function next():Int return 0; } function main():Int { for (x in new Bad()) {} return 0; }',
			'class Bad { public function new() {} public function hasNext():Bool return false; public function next():Void {} } function main():Int { for (x in new Bad()) {} return 0; }',
			'class Bad { public function new() {} public function iterator():Int return 0; } function main():Int { for (x in new Bad()) {} return 0; }',
			'function consume(values:Iterable<Int>):Int return 0; function main():Int return consume(["wrong"]);',
			'class Bad { public function new() {} public function hasNext():Bool return false; public function next():String return "wrong"; } function main():Int { var it:Iterator<Int> = new Bad(); return 0; }'
		]) {
			var rejected = false, invalidCompiler = new Compiler();
			invalidCompiler.update("Main.hx", invalid);
			try
				invalidCompiler.compile("Main")
			catch (error:compiler.Diagnostic.CompileError) {
				if (error.diagnostic.code != "E1014" && error.diagnostic.code != "E1009" && error.diagnostic.code != "E1002")
					throw error;
				rejected = true;
			}
			if (!rejected)
				throw "Malformed iteration protocol was accepted";
		}
		Sys.println("PASS: structural iteration");
	}
}
