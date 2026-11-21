import compiler.Compiler;
import compiler.compilation.PipelineSnapshot;

/**
 * Making a parameter optional (`p:T` -> `?p:T`, or giving it a default) changes how many arguments callers may pass,
 * so it is a signature change even though the parameter types are identical. An incremental build must notice it:
 * a caller edited to omit the argument has to be typed against the new signature, not the one compiled earlier.
 */
class OptionalParameterSignatureMain {
	static function check(label:String, gateBefore:String, gateAfter:String, mainBefore:String, mainAfter:String):Void {
		var compiler = new Compiler();
		compiler.update("Gate.hx", gateBefore);
		compiler.update("Main.hx", mainBefore);
		compiler.compile("Main", null, false);
		compiler.update("Gate.hx", gateAfter);
		compiler.update("Main.hx", mainAfter);
		try {
			compiler.compile("Main", null, false);
		} catch (error:Dynamic)
			throw '$label: incremental build kept the old signature: $error';
	}

	/**
	 * A caller that omits an optional argument is lowered with the default, so editing the default must give the program a
	 * fresh build of the edited sources has, even though the signature types and arity are unchanged and the caller still
	 * type-checks. Where the default is applied (the caller, or a dispatch wrapper it calls) is the lowering's choice; a
	 * function whose IR the edit does not change keeps it, so the check is the final program, not which functions were
	 * regenerated.
	 */
	static function checkDefault(label:String, gateBefore:String, gateAfter:String, caller:String):Void {
		var compiler = new Compiler();
		compiler.update("Gate.hx", gateBefore);
		compiler.update("Main.hx", caller);
		compiler.compile("Main", null, false);
		compiler.update("Gate.hx", gateAfter);
		var changed = compiler.compile("Main", null, false);
		var fresh = new Compiler();
		fresh.update("Gate.hx", gateAfter);
		fresh.update("Main.hx", caller);
		var difference = PipelineSnapshot.irDifference(changed.ir, fresh.compile("Main", null, false).ir);
		if (difference != null)
			throw '$label: the caller kept the old default: $difference (regenerated ${changed.regenerated})';
	}

	static function main():Void {
		var instanceBefore =
			"class Gate { public function new() {} public function go(id:String, point:Array<Float>):Int return point == null ? 0 : 1; }";
		var instanceAfter =
			"class Gate { public function new() {} public function go(id:String, ?point:Array<Float>):Int return point == null ? 0 : 1; }";
		var staticBefore =
			"class Gate { public static function go(id:String, point:Array<Float>):Int return point == null ? 0 : 1; }";
		var staticAfter =
			"class Gate { public static function go(id:String, ?point:Array<Float>):Int return point == null ? 0 : 1; }";
		var instanceCallBefore =
			"class Main { static function main():Int { var g = new Gate(); return g.go(\"a\", [1.0]); } }";
		var instanceCallAfter = "class Main { static function main():Int { var g = new Gate(); return g.go(\"a\"); } }";
		var staticCallBefore = "class Main { static function main():Int return Gate.go(\"a\", [1.0]); }";
		var staticCallAfter = "class Main { static function main():Int return Gate.go(\"a\"); }";
		check("instance, caller edited", instanceBefore, instanceAfter, instanceCallBefore, instanceCallAfter);
		check("static, caller edited", staticBefore, staticAfter, staticCallBefore, staticCallAfter);
		check("instance, caller unchanged", instanceBefore, instanceAfter, instanceCallBefore, instanceCallBefore);
		check("static, caller unchanged", staticBefore, staticAfter, staticCallBefore, staticCallBefore);
		var defaultAfter =
			"class Gate { public function new() {} public function go(id:String, point:Array<Float> = null):Int return point == null ? 0 : 1; }";
		check("instance, default value", instanceBefore, defaultAfter, instanceCallBefore, instanceCallAfter);
		checkDefault("instance, default changes",
			"class Gate { public function new() {} public function scale(v:Float = 1.0):Float return v; }",
			"class Gate { public function new() {} public function scale(v:Float = 3.0):Float return v; }",
			"class Main { static function main():Int { var g = new Gate(); return g.scale() > 0.5 ? 0 : 1; } }");
		checkDefault("static, default changes",
			"class Gate { public static function scale(v:Float = 1.0):Float return v; }",
			"class Gate { public static function scale(v:Float = 3.0):Float return v; }",
			"class Main { static function main():Int return Gate.scale() > 0.5 ? 0 : 1; }");
		Sys.println("PASS: making a parameter optional, or changing its default, is a signature change for incremental builds");
	}
}
