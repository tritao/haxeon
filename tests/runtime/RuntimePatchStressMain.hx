import compiler.Compiler;
import compiler.hl.HlWriter;
import runtime.PatchSet;
import runtime.Runtime;
import runtime.memory.Gc;

class RuntimePatchStressMain {
	#if haxeon
	static function main():Void {
		var configured = Sys.getEnv("HAXEON_RUNTIME_STRESS_ITERATIONS"),
			iterations = 1000;
		if (configured != null)
			iterations = cast Std.parseInt(configured);
		if (iterations <= 0)
			throw "Haxeon runtime stress iterations must be a positive integer";

		var compiler = new Compiler();
		compiler.update("GoldenMain.hx",
			"class Box { public var value:Int; public function new(value:Int) { this.value = value; } } function main():Int return 10; function makeObject():Box return new Box(7); function readObject(box:Box):Int return box.value;");
		var previous = compiler.compile("GoldenMain"),
			mainId:Int = cast previous.functionIds.get("main"),
			makeObjectId:Int = cast previous.functionIds.get("GoldenMain.makeObject"),
			readObjectId:Int = cast previous.functionIds.get("GoldenMain.readObject"),
			loaded = Runtime.load(HlWriter.encode(previous.module), previous.runtimeIdentity),
			oldObject = Runtime.retainObject(loaded, makeObjectId);
		if (Runtime.debugHlbSize(loaded) != 0
			|| Runtime.callInt(loaded, mainId) != 10
			|| Runtime.callIntObject(loaded, readObjectId, oldObject) != 7)
			throw "Haxe-owned stress module did not execute its initial generation";

		for (iteration in 1...iterations + 1) {
			var value = 10 + iteration;
			compiler.update("GoldenMain.hx",
				'class Box { public var value:Int; public function new(value:Int) { this.value = value; } } function main():Int return $value; function makeObject():Box return new Box(7); function readObject(box:Box):Int return box.value;');
			var next = compiler.compile("GoldenMain"),
				patchBytes = next.patchBytes;
			if (patchBytes == null)
				throw "Haxe-owned stress compilation did not produce a patch";
			Runtime.patchSet(loaded, new PatchSet(previous.revision, next.revision, patchBytes, next.changedFunctions));
			if (Runtime.callInt(loaded, mainId) != value
				|| Runtime.callIntObject(loaded, readObjectId, oldObject) != 7
				|| loaded.retiredPatchCount() != iteration - 1)
				throw 'Haxe-owned stress patch failed at iteration $iteration';
			if (iteration % 8 == 0)
				Gc.collect();
			previous = next;
		}

		Gc.collect();
		if (Runtime.retirementStatus(loaded).haxeBorrowers != 1)
			throw "Haxe-owned stress object was not retained through the patch loop";
		Runtime.dispose(loaded);
		if (Runtime.retryRetirements() != 1)
			throw "Haxe-owned stress retirement was not deferred by the retained object";
		oldObject.release();
		var pending = 1;
		for (_ in 0...4) {
			Gc.collect();
			pending = Runtime.retryRetirements();
			if (pending == 0)
				break;
		}
		if (pending != 0)
			throw "Haxe-owned stress retirement remained blocked after releasing the object";
		Runtime.drainRetirements();
		Sys.println('PASS: Haxe-owned runtime survived $iterations patch/execute/GC iterations');
	}
	#else
	static function main():Void {}
	#end
}
