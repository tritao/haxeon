import compiler.Compiler;
import compiler.hl.HlWriter;
import runtime.LoadedModule;
import runtime.RetainedValue;
import runtime.Runtime;
import hl.Gc;

/**
	A module is retired only once nothing it allocated is reachable. Its objects live in pages of its own, and the
	slot for those pages is handed on to the next module, so far more modules than slots can come and go. When more
	are loaded at once than there are slots, the extra ones share pages and wait for each other.
**/
class GcOwnerRetirementMain {
	static function load(bytes:haxe.io.Bytes, identity:haxe.io.Bytes, make:Int, loaded:Array<LoadedModule>, retained:Array<RetainedValue>) {
		var module = Runtime.load(bytes, identity);
		var closure = Runtime.retainClosure(module, make);
		if (Runtime.callRetainedClosureInt(closure) != 42)
			throw "new module capture";
		loaded.push(module);
		retained.push(closure);
	}

	static function collect() {
		Gc.major();
		Gc.major();
	}

	static function main() {
		var compiler = new Compiler();
		compiler.update("Main.hx", "class Box { public var value:Int; public function new(value:Int) { this.value = value; } }
function makeBox():Box { return new Box(42); }
function make():() -> Int { var values = [40, 2]; return function() return values[0] + values[1]; } function main():Int { return 42; }");
		var compiled = compiler.compile("Main");
		var bytes = HlWriter.encode(compiled.module);
		var make = compiled.functionIds.get("Main.make");

		// A plain object of the module is a block of the module like any other, however the JIT allocated it.
		for (generation in 0...3) {
			var module = Runtime.load(bytes, compiled.runtimeIdentity);
			var box = Runtime.retainObject(module, compiled.functionIds.get("Main.makeBox"));
			Runtime.dispose(module);
			collect();
			if (Runtime.retryRetirements() == 0)
				throw 'module retired while one of its objects was held, generation $generation';
			box.release();
			collect();
			if (Runtime.retryRetirements() != 0)
				throw 'module retirement blocked after its object was dropped, generation $generation';
		}

		// One after the other: the module is blocked while its closure is held, and retires once it is dropped.
		for (generation in 0...40) {
			var loaded = [], retained = [];
			load(bytes, compiled.runtimeIdentity, make, loaded, retained);
			Runtime.dispose(loaded[0]);
			collect();
			if (Runtime.retryRetirements() == 0)
				throw 'module retired while its closure was held, generation $generation';
			if (Runtime.callRetainedClosureInt(retained[0]) != 42)
				throw "capture lost while the module was blocked";
			retained[0].release();
			collect();
			if (Runtime.retryRetirements() != 0)
				throw 'module retirement blocked after its closure was dropped, generation $generation';
		}

		// More at once than there are slots: no module retires while anything of its own is held.
		var loaded = [], retained = [];
		for (i in 0...20)
			load(bytes, compiled.runtimeIdentity, make, loaded, retained);
		for (module in loaded)
			Runtime.dispose(module);
		collect();
		if (Runtime.retryRetirements() != 20)
			throw "modules retired while their closures were held";
		for (i in 0...20)
			if (Runtime.callRetainedClosureInt(retained[i]) != 42)
				throw 'capture $i lost while its module was blocked';
		// Dropping all but one: the one still held, whether it has a slot of its own or shares, keeps its module.
		for (i in 0...19)
			retained[i].release();
		collect();
		var pending = Runtime.retryRetirements();
		if (pending < 1)
			throw "the module whose closure is still held retired";
		if (Runtime.callRetainedClosureInt(retained[19]) != 42)
			throw "capture lost after its neighbours retired";
		retained[19].release();
		collect();
		if (Runtime.retryRetirements() != 0)
			throw "modules stayed blocked after everything was dropped";

		// The slots are free again.
		for (generation in 0...20) {
			var loaded = [], retained = [];
			load(bytes, compiled.runtimeIdentity, make, loaded, retained);
			Runtime.dispose(loaded[0]);
			retained[0].release();
			collect();
			if (Runtime.retryRetirements() != 0)
				throw 'module retirement blocked after the overflow, generation $generation';
		}
		Sys.println("PASS: module retirement follows what each module's own pages hold across slot reuse and overflow");
	}
}
