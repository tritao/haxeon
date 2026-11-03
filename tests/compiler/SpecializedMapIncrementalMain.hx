import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/** Type-only map dependencies and their specialized owners survive incremental edits. */
class SpecializedMapIncrementalMain {
	static function main():Void {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.addSourceRoot("stdlib");
		compiler.update("Value.hx", "struct Value { public var number:Int; public function new(number:Int) this.number = number; }");
		compiler.update("Holder.hx", "class Holder { public var entries:Map<Int, Value>; public function new() {} }");
		compiler.update("Main.hx", "class Main { static function main():Int { var h = new Holder(); return h == null ? 1 : 42; } }");
		var first = compiler.compile("Main");
		if (GeneratedProgramRunner.exitCode(first) != 42) throw "type-only map field changed behavior";
		assertOwner(first.ir, true);
		compiler.update("Main.hx", "class Main { static function main():Int { var h = new Holder(); h.entries = new Map(); h.entries.set(1, new Value(42)); var v = h.entries.get(1); return v == null ? 1 : v.number; } }");
		var second = compiler.compile("Main");
		if (GeneratedProgramRunner.exitCode(second) != 42) throw "map operations after edit lost their owner";
		assertOwner(second.ir, true);
		compiler.update("Holder.hx", "class Holder { public var entries:Map<Int, Int>; public function new() {} }");
		compiler.update("Main.hx", "class Main { static function main():Int { var h = new Holder(); return h == null ? 1 : 42; } }");
		var third = compiler.compile("Main");
		if (GeneratedProgramRunner.exitCode(third) != 42) throw "map type edit changed behavior";
		assertOwner(third.ir, false);
		Sys.println("PASS: specialized map type dependencies and incremental pruning");
	}

	static function assertOwner(program:compiler.ir.Ir.IrProgram, expected:Bool):Void {
		var found = false;
		for (object in program.objects) {
			if (StringTools.startsWith(object.name, "__haxeon_hashable_map_")) throw "old generated map object remains";
			if (object.name.indexOf("$owner:haxeon.collections.HashMap") >= 0) found = true;
		}
		if (found != expected) throw 'specialized map owner present=$found, expected=$expected';
	}
}
