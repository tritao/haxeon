import compiler.Compiler;

/** An explicit import outranks a same-named unpackaged type elsewhere in the program. */
class ImportOutranksRootTypeMain {
	static function main():Void {
		var compiler = new Compiler();
		// An unpackaged Path, like UiKit's, reached by another module.
		compiler.update("Path.hx", "class Path { public var drawing:Bool = true; public function new() {} }");
		compiler.update("Canvas.hx", "class Canvas { public static function stroke():Bool return new Path().drawing; }");
		compiler.update("nav/Path.hx", "package nav; class Path { public final length:Float; public function new(length:Float) this.length = length; }");
		compiler.update("user/Route.hx",
			"package user; import nav.Path; class Route { " + "public static function make():Path return new Path(3.0); " +
			"public static function main():Int return Canvas.stroke() ? Std.int(make().length) : 0; }");
		compiler.analyze("user.Route");
		Sys.println("PASS: an imported Path outranks the unpackaged Path, which still resolves without the import");
	}
}
