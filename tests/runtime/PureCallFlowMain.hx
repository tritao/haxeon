import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** `@:pure` calls keep nullable field refinements that other calls invalidate. */
class PureCallFlowMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx",
			"import Math;\n"
			+ "typedef Limits = {var lower:Null<Float>; var upper:Null<Float>;};\n"
			+ "@:pure class Checks { public static function positive(value:Float):Bool return value > 0; }\n"
			+ "class Local { @:pure public static function small(value:Float):Bool return value < 100; }\n"
			+ "function invalid(limits:Null<Limits>):Bool {\n"
			+ "  if (limits == null) return false;\n"
			+ "  return (limits.lower != null && (!Math.isFinite(limits.lower) || !Checks.positive(limits.lower) || limits.lower < 1))\n"
			+ "    || (limits.upper != null && (!Local.small(limits.upper) || Math.abs(limits.upper) < 2));\n"
			+ "}\n"
			+ "function main():Int return !invalid({lower: 3.0, upper: 50.0}) && invalid({lower: 0.5, upper: null})\n"
			+ "  && invalid({lower: null, upper: 500.0}) && !invalid(null) ? 42 : 1;");
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
		Sys.println("PASS: @:pure calls preserve nullable field refinements");
	}
}
