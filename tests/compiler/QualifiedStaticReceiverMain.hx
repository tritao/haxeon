import compiler.Compiler;

/** Method calls whose receiver is a static field reached through a qualified type path. */
class QualifiedStaticReceiverMain {
	static final HOLDER = "package shapes; class Box { public var sides:Array<Int>; public function new() sides = [4, 6]; } "
		+ "class Holder { public static final VALUES:Array<Int> = [1, 2, 3]; public static final BOX = new Box(); "
		+ "public static function values():Array<Int> return VALUES; }";

	static function main():Void {
		var samePackage = new Compiler();
		samePackage.update("shapes/Holder.hx", HOLDER);
		samePackage.update("shapes/Main.hx",
			"package shapes; class Main { static function main():Int return Holder.VALUES.indexOf(2) + Holder.BOX.sides.indexOf(6); }");
		samePackage.analyze("shapes.Main");
		Sys.println("PASS: same-package static field receivers resolve");

		var qualified = new Compiler();
		qualified.update("shapes/Holder.hx", HOLDER);
		qualified.update("Main.hx",
			"class Main { static function main():Int return shapes.Holder.VALUES.indexOf(3) + shapes.Holder.BOX.sides.indexOf(4) + shapes.Holder.values().length; }");
		qualified.analyze("Main");
		Sys.println("PASS: fully qualified static field receivers resolve");

		var imported = new Compiler();
		imported.update("shapes/Holder.hx", HOLDER);
		imported.update("Main.hx",
			"import shapes.Holder; class Main { var shapes:String = 'unrelated'; public function new() {} function run():Int return Holder.VALUES.indexOf(2); static function main():Int return new Main().run(); }");
		imported.analyze("Main");
		Sys.println("PASS: imported receiver ignores an introduced package root shadowed by a field");

		imported.update("Main.hx",
			"import shapes.Holder; class Main { var shapes:String = 'updated'; public function new() {} function run():Int return Holder.BOX.sides.indexOf(6); static function main():Int return new Main().run(); }");
		imported.analyze("Main");
		Sys.println("PASS: imported receiver provenance survives incremental reanalysis");

		var aliasShadowed = new Compiler();
		aliasShadowed.update("shapes/Holder.hx", HOLDER);
		aliasShadowed.update("Main.hx",
			"import shapes.Holder; class Main { static function main():Int { var Holder = { VALUES: [9] }; return Holder.VALUES.indexOf(9); } }");
		aliasShadowed.analyze("Main");
		Sys.println("PASS: source alias value still shadows an imported type");

		var shadowed = new Compiler();
		shadowed.update("shapes/Holder.hx", HOLDER);
		shadowed.update("Main.hx",
			"class Main { static function main():Int { var shapes = { Holder: { VALUES: [9] } }; return shapes.Holder.VALUES.indexOf(9); } }");
		shadowed.analyze("Main");
		Sys.println("PASS: a local value shadows a package of the same name");
	}
}
