import compiler.hl.HlWriter;
import compiler.Compiler;
import sys.io.File;

/** `import pkg.Module.member` brings a static member of the module's class, or a function declared in the module, into scope. */
class StaticImportMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("util/Helpers.hx",
			"package util; class Helpers { public static final LIMIT:Int = 5; public static function triple(value:Int):Int { return value * 3; } public static function clamp(value:Int, high:Int):Int { return value > high ? high : value; } } function plain(value:Int):Int { return value + 100; } class Other { public static function ten():Int { return 10; } }");
		compiler.update("Main.hx",
			"import util.Helpers.triple; import util.Helpers.clamp; import util.Helpers.LIMIT; import util.Helpers.plain; import util.Helpers.Other; function main():Int { var total = triple(4) + clamp(50, 7) + LIMIT + plain(1) + Other.ten(); return total == 12 + 7 + 5 + 101 + 10 ? 42 : 1; }");
		var result = compiler.compile("Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
