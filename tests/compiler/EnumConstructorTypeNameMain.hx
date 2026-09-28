import compiler.Compiler;

/** Imported enum constructors named like built-in types stay out of type positions. */
class EnumConstructorTypeNameMain {
	static final MOTION = "package sim; enum abstract MotionType(Int) from Int to Int { var Static = 0; var Kinematic = 1; var Dynamic = 2; }";

	static function main():Void {
		var typePosition = new Compiler();
		typePosition.update("sim/MotionType.hx", MOTION);
		typePosition.update("Main.hx",
			"import sim.MotionType; class Main { static function main():Int { var anything:Dynamic = 1; " +
			"try { throw 'x'; } catch (_:Dynamic) {} return MotionType.Dynamic; } }");
		typePosition.analyze("Main");
		Sys.println("PASS: Dynamic in type positions is the built-in type");

		var expression = new Compiler();
		expression.update("sim/MotionType.hx", MOTION);
		expression.update("Main.hx",
			"import sim.MotionType; class Main { static function main():Int { var motion:MotionType = Dynamic; " +
			"return switch motion { case Dynamic: 2; case Kinematic: 1; default: 0; }; } }");
		expression.analyze("Main");
		Sys.println("PASS: the imported constructor still resolves in expressions and patterns");
	}
}
