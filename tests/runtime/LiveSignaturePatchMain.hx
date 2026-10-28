import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/**
 * An edit that changes a function's signature, a parameter added to a constructor say, patches: the function takes a new slot
 * and the old one keeps its code. Callers the patch compiles again call the new function; closures made before the edit keep
 * calling the old one, as do objects it made. A method an object's prototype dispatches to keeps its slot, so changing its
 * signature still reloads.
 */
class LiveSignaturePatchMain {
	static function program(version:Int):String {
		var base = version == 1 ? "  public function new(a:Int) { this.a = a; }\n" : "  public function new(a:Int, b:Int) { this.a = a + b; }\n";
		var point = switch version {
			case 1: "  public function new(x:Int) { super(x); this.y = 0; }\n";
			case 2: "  public function new(x:Int, y:Int) { super(x, 1); this.y = y; }\n";
			default: "  public function new(x:Int) { super(x, 2); this.y = 1; }\n";
		};
		var scale = switch version {
			case 1: "function scale(v:Int):Int return v * 2;\n";
			case 2: "function scale(v:Int, by:Int):Int return v * by;\n";
			default: "function scale(v:Int):Int return v * 5;\n";
		};
		var made = switch version {
			case 1: "new Point(3)";
			case 2: "new Point(3, 0)";
			default: "new Point(3)";
		};
		var scaler = version == 2 ? "v -> scale(v, 2)" : "scale";
		var fresh = version == 2 ? "new Point(5, 7)" : "new Point(5)";
		var once = version == 2 ? "scale(1, 3)" : "scale(1)";
		return "class Base {\n"
			+ "  public var a:Int;\n"
			+ base
			+ "}\n"
			+ "class Point extends Base {\n"
			+ "  public var y:Int;\n"
			+ point
			+ "  public function sum():Int return a + y;\n"
			+ "}\n"
			+ "class Holder {\n"
			+ "  public static var kept:Null<Point> = null;\n"
			+ "  public static var scaler:Null<Int->Int> = null;\n"
			+ "}\n"
			+ scale
			+ "function main():Int {\n"
			+ "  if (Holder.kept == null) { Holder.kept = " + made + "; Holder.scaler = " + scaler + "; }\n"
			+ "  var kept:Point = Holder.kept;\n"
			+ "  var scaler:Int->Int = Holder.scaler;\n"
			+ "  return kept.sum() * 100000 + " + fresh + ".sum() * 1000 + scaler(4) * 10 + " + once + ";\n"
			+ "}\n";
	}

	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", program(1));
		var build = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			mainId = build.functionIds.get("main");
		// The kept point sums 3, a new one 5, the stored scaler doubles 4, and scale(1) is 2.
		expect(Runtime.callInt(live, mainId), 305082, "before the edits");

		// Constructors of a class and its base, and a static function, each take a parameter more.
		compiler.update("Main.hx", program(2));
		var second = compiler.compile("Main");
		build = apply(live, build, second, "parameters added");
		// The kept point is the one made before (3); a new one is (5 + 1) + 7; the stored closure still runs the old scale.
		expect(Runtime.callInt(live, mainId), 313083, "after the parameters were added");
		expect(runFresh(second), 413083, "the full module after the parameters were added");

		// And back: the signatures change again, to the ones they first had.
		compiler.update("Main.hx", program(3));
		var third = compiler.compile("Main");
		build = apply(live, build, third, "parameters removed again");
		expect(Runtime.callInt(live, mainId), 308085, "after the parameters were removed again");
		expect(runFresh(third), 608205, "the full module after the parameters were removed again");
		Runtime.dispose(live);

		// A reload lays the module out afresh, and the functions the moves above retired go with the old module.
		compiler.update("Main.hx", StringTools.replace(program(3), "class Holder {", "enum Shape { Dot; }\nclass Holder {"));
		var reloaded = compiler.compile("Main");
		if (!reloaded.requiresReload)
			throw 'Adding an enum must reload';
		var retired = [for (name in (reloaded.functionIds : Map<String, Int>).keys()) if (name.indexOf("~retired") >= 0) name];
		if (retired.length > 0)
			throw 'A reload kept the retired functions ${retired.join(", ")}';
		var again = compiler.compile("Main");
		var kept = [for (name in (again.functionIds : Map<String, Int>).keys()) if (name.indexOf("~retired") >= 0) name];
		if (kept.length > 0)
			throw 'The build after a reload still names the retired functions ${kept.join(", ")}';

		// A method's prototype entry names its slot, so a method signature change still reloads, and says why.
		var methods = new Compiler();
		methods.update("Main.hx", program(1));
		methods.compile("Main");
		methods.update("Main.hx", StringTools.replace(StringTools.replace(program(1), "sum():Int return a + y;", "sum(extra:Int):Int return a + y + extra;"),
			"kept.sum()", "kept.sum(0)").split(".sum() * 1000").join(".sum(0) * 1000"));
		var refused = methods.compile("Main");
		var reasons = [for (reason in refused.reloadReasons) Std.string(reason)];
		if (!refused.requiresReload || reasons.indexOf("FunctionSignatureChanged(Point.sum)") < 0)
			throw 'A method signature change must reload with FunctionSignatureChanged(Point.sum); reasons: ${reasons.join(", ")}';
		Sys.println("PASS: changed constructor and function signatures patch, and a changed method signature reloads");
	}

	static function apply(live:runtime.LoadedModule, build:Dynamic, changed:Dynamic, label:String):Dynamic {
		if (changed.requiresReload || changed.patchBytes == null)
			throw '$label: required a reload: ${[for (reason in (changed.reloadReasons : Array<Dynamic>)) Std.string(reason)].join(", ")}';
		Runtime.patchSet(live, new PatchSet(build.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		return changed;
	}

	static function runFresh(build:Dynamic):Int {
		var fresh = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity);
		var value = Runtime.callInt(fresh, build.functionIds.get("main"));
		Runtime.dispose(fresh);
		return value;
	}

	static function expect(actual:Int, expected:Int, label:String):Void
		if (actual != expected)
			throw '$label: the program returned $actual instead of $expected';
}
