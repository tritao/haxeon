import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/** A function that passes a native as a value builds a static closure of it, and must still be patchable. The closure is
	also called dynamically, which reads its type, so the patched code must give it the native's type. */
class NativeClosurePatchMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("StdMath.hx", '@:hlNative("std") extern class StdMath { static function math_sqrt(value:Float):Float; }');
		var program = (offset:Int) -> "class Calc { static function apply(f:Float->Float, value:Float):Float return f(value); "
			+ "public static function run():Int { var root = StdMath.math_sqrt; var dynamicRoot:Dynamic = root; "
			+ "return (apply(root, 16.0) == 4.0 ? 2 : 0) + (dynamicRoot(4.0) == 2.0 ? 2 : 0) + "
			+ offset
			+ "; } } function main():Int { return Calc.run(); }";
		compiler.update("Main.hx", program(1));
		var first = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(first.module), first.runtimeIdentity),
			mainId = first.functionIds.get("main");
		if (Runtime.callInt(live, mainId) != 5)
			throw "The native-closure program did not run correctly before the edit";
		compiler.update("Main.hx", program(2));
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw "A body edit did not produce a compatible patch";
		Runtime.patchSet(live, new PatchSet(first.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		if (Runtime.callInt(live, mainId) != 6)
			throw "The patched function kept its old body";
		Runtime.dispose(live);
		Sys.println("PASS: a function that takes a native as a value is patchable");
	}
}
