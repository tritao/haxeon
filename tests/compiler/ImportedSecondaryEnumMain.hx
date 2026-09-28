import compiler.Compiler;

/** Importing a module and one of its secondary enums brings the enum's constructors into expressions. */
class ImportedSecondaryEnumMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("app/Layout.hx",
			"package app; enum Density { Full; Compact; } " +
			"class Layout { public static function pick(previous:Density):Density return switch previous { case Full: Compact; case Compact: Full; } }");
		compiler.update("Main.hx",
			"import app.Layout; import app.Layout.Density; class Main { " +
			"static function main():Int { var density = Full; density = Layout.pick(density); return density == Compact ? 1 : 0; } }");
		compiler.analyze("Main");
		Sys.println("PASS: an imported secondary enum's constructors resolve alongside its module import");
	}
}
