import compiler.Compiler;

/**
 * A bare name where an enum abstract value is expected means that value, even when a class of the same
 * name is in the program: compared with a value of the abstract, as a switch case, as an initializer, and
 * as an argument. The class stays reachable by its own name wherever no value is expected.
 */
class EnumAbstractValueShadowedByClassMain {
	/** A program whose Owner uses the class Carry, so it is loaded, beside a member that names the value. */
	static function program(member:String):Compiler {
		var compiler = new Compiler();
		compiler.update("Carry.hx", "class Carry { public static final SPEED = 3; public function new() {} }");
		compiler.update("Mode.hx", "enum abstract Mode(Int) { var Free = 0; var Carry = 1; var Hang = 2; }");
		compiler.update("Owner.hx",
			"class Owner { public var mode:Mode = Mode.Free; public function new() {} "
			+ "public function speed():Int return Carry.SPEED; "
			+ member
			+ " }");
		compiler.update("Main.hx",
			"class Main { static function main():Int { var owner = new Owner(); return owner.check() && owner.speed() == 3 ? 0 : 1; } }");
		return compiler;
	}

	/**
	 * The same, inside a package: a bare name that also names a class of that package is handed to the
	 * typer qualified by it, and the value is still what it means. The value is read through a property
	 * of another object, as real code does.
	 */
	static function packaged(member:String):Compiler {
		var compiler = new Compiler();
		compiler.update("pk/Carry.hx", "package pk; class Carry { public static final SPEED = 3; public function new() {} }");
		compiler.update("pk/Mode.hx", "package pk; enum abstract Mode(Int) { var Free = 0; var Carry = 1; var Hang = 2; }");
		compiler.update("pk/Control.hx", "package pk; class Control { public var mode(default, null):Mode = Mode.Free; public function new() {} }");
		compiler.update("pk/Body.hx",
			"package pk; class Body { final control = new Control(); public function new() {} "
			+ "public function speed():Int return Carry.SPEED; "
			+ member
			+ " }");
		compiler.update("Main.hx", "class Main { static function main():Int { var body = new pk.Body(); return body.check() && body.speed() == 3 ? 0 : 1; } }");
		return compiler;
	}

	static function main():Void {
		var forms = [
			"equality" => "public function check():Bool return mode == Carry;",
			"inequality" => "public function check():Bool return mode != Carry;",
			"switch case" => "public function check():Bool { return switch mode { case Free: true; case Carry: false; default: false; } }",
			"switch over a derived value" => "public function check():Bool { var wanted = mode == Free && true ? Mode.Hang : mode; " +
			"return switch wanted { case Free: true; case Carry: false; default: false; }; }",
			"comparison with a derived value" => "public function check():Bool { var wanted = mode == Free && true ? Mode.Hang : mode; " +
			"if (wanted == Carry) return false; return true; }",
			"typed local" => "public function check():Bool { var m:Mode = Carry; return m != mode; }",
			"argument" => "public function take(m:Mode):Bool return m == Mode.Free; public function check():Bool return take(Carry);"
		];
		var failures:Array<String> = [];
		for (name => member in forms)
			try
				program(member).analyze("Main")
			catch (error:Dynamic)
				failures.push('$name: ${Std.string(error)}');
		var packagedForms = [
			"packaged equality" => "public function check():Bool return control.mode == Carry;",
			"packaged condition" => "public function check():Bool { if (control.mode == Carry || control.mode != Free) return true; return false; }",
			"packaged switch" => "public function check():Bool { return switch control.mode { case Free: true; case Carry: false; default: false; } }"
		];
		for (name => member in packagedForms)
			try
				packaged(member).analyze("Main")
			catch (error:Dynamic)
				failures.push('$name: ${Std.string(error)}');
		if (failures.length > 0)
			throw "A like-named class shadowed an enum abstract value:\n" + failures.join("\n");
		Sys.println("PASS: an enum abstract value outranks a like-named class where that abstract is expected");
	}
}
