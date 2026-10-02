import compiler.Compiler;

/** A type in the current package outranks a same-named unpackaged type elsewhere in the program. */
class SamePackageOutranksRootTypeMain {
	static function main():Void {
		var compiler = new Compiler();
		// An unpackaged Path, like UiKit's, reached by another module.
		compiler.update("Path.hx", "class Path { public var drawing:Bool = true; public function new() {} }");
		compiler.update("Canvas.hx", "class Canvas { public static function stroke():Bool return new Path().drawing; }");
		compiler.update("nav/Path.hx", "package nav; class Path { public final length:Float; public function new(length:Float) this.length = length; }");
		// No import: in package nav, a plain Path is nav.Path, as RobotKit's planner writes it.
		compiler.update("nav/Planner.hx",
			"package nav; class Planner { " + "public static function plan():Path return new Path(3.0); " +
			"public static function main():Int return Canvas.stroke() ? Std.int(plan().length) : 0; }");
		compiler.analyze("nav.Planner");
		Sys.println("PASS: a same-package Path outranks the unpackaged Path, which still resolves elsewhere");
	}
}
