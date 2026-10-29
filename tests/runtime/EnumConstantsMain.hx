import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.types.Type.CompilerType;
import sys.io.File;

/**
 * An enum constructor without fields denotes one value: it is made the first time it is evaluated and kept, not made
 * again at every evaluation. Constructors with fields still make a value each time, and still match in a switch.
 */
class EnumConstantsMain {
	static final source = 'enum Mode { Auto; None; Wide(n:Int); }
function pick(i:Int):Mode return i % 3 == 0 ? Mode.Auto : i % 3 == 1 ? Mode.None : Mode.Wide(i);
function main():Int {
	var kept:Array<Mode> = [for (_ in 0...1000) Mode.Auto];
	var before = allocated();
	for (i in 0...1000) kept[i] = Mode.Auto;
	var used = allocated() - before;
	var same = kept[0] == Mode.Auto && kept[999] == Mode.Auto && Mode.Auto != Mode.None && kept[500] != Mode.None;
	var wide = switch (pick(5)) { case Wide(n): n; default: -1; };
	var auto = switch (pick(0)) { case Auto: true; default: false; };
	var none = switch (pick(1)) { case None: true; default: false; };
	return used < 1000.0 && same && wide == 5 && auto && none ? 42 : 1;
}';

	static function build(live:Bool):Compiler {
		var compiler = new Compiler();
		compiler.livePatching = live;
		compiler.registerNative("allocated", "std", "gc_total_allocated", [], CompilerType.TFloat);
		compiler.update("Main.hx", source);
		return compiler;
	}

	static function main():Void {
		var fixed = build(false).compile("Main");
		build(true).compile("Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(fixed.module));
	}
}
