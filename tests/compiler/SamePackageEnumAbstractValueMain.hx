import compiler.Compiler;

/**
 * A switch over an enum abstract from the current package names its values
 * bare, even when an enum abstract elsewhere declares the same value name.
 */
class SamePackageEnumAbstractValueMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("VisualKind.hx", "enum abstract VisualKind(Int) from Int to Int { var Box = 1; var Text = 2; }");
		compiler.update("shapes/ShapeType.hx", "package shapes; enum abstract ShapeType(Int) from Int to Int { var Box = 1; var Sphere = 2; }");
		compiler.update("shapes/Shape.hx",
			"package shapes; class Shape { public final type:ShapeType; public function new(type:ShapeType) this.type = type; " +
			"public function radius():Float return switch type { case Box: 2.0; case Sphere: 1.0; default: 0.0; } }");
		compiler.update("Main.hx",
			"class Main { static function main():Int { var kind:VisualKind = VisualKind.Text; " +
			"return new shapes.Shape(shapes.ShapeType.Box).radius() == 2.0 && (kind:Int) == 2 ? 0 : 1; } }");
		compiler.analyze("Main");
		Sys.println("PASS: a same-package enum abstract value outranks a like-named value elsewhere");
	}
}
