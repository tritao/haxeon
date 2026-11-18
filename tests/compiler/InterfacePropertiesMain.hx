import compiler.Frontend;
import compiler.core.Diagnostic.CompileError;

/**
 * An interface's variables and properties are checked as Haxe 4.3.7 checks them (typeloadCheck's `check_interface`), with its
 * words and at its places: an implementing class has each, public, with an access that unifies with the interface's and the same
 * type, and the accessors of its `get` and `set` sides; an access through the interface follows the interface's sides
 * (tests/differential/interface-variables*.hx run the accepted forms against it).
 */
class InterfacePropertiesMain {
	static function main():Void {
		expectError("a property for a variable", "interface I { var x:Int; } "
			+ "class C implements I { public var x(get, set):Int; function get_x() return 0; function set_x(v) return v; } ",
			"Field x has different property access than in I ((get,set) should be var)", "x(get, set)");
		expectError("a variable for a property", "interface I { var y(get, never):Int; } "
			+ "class C implements I { public var y:Int = 0; function get_y() return 0; } ",
			"Field y has different property access than in I (var should be (get,never))", "y:Int = 0");
		expectError("a missing accessor", "interface I { var y(get, never):Int; var x:Int; } class C implements I { } ",
			"Field get_y needed by I is missing", "C implements");
		expectError("a missing variable", "interface I { var x:Int; } class C implements I { } ",
			"Field x needed by I is missing", "C implements");
		expectError("a private variable", "interface I { var x:Int; } class C implements I { var x:Int = 0; } ",
			"Field x should be public as requested by I", "x:Int = 0");
		expectError("another type", "interface I { var x:Int; } class C implements I { public var x:Float = 0; } ",
			"Field x has different type than in I", "x:Float");
		expectError("a method for a variable",
			"interface I { var x:Int; } class C implements I { public function x() return 0; } ",
			"Field x has different property access than in I (method should be var)", "x() return");
		expectError("a read-only variable for a variable", "interface I { var x:Int; } "
			+ "class C implements I { public var x(default, null):Int; } ",
			"Field x has different property access than in I ((default,null) should be var)", "x(default");
		expectError("a variable for a final",
			"interface I { final x:Int; } class C implements I { public var x:Int = 1; } ",
			"Field x has different property access than in I (var should be (default,ctor))", "x:Int = 1");
		expectError("an accessor of another type", "interface I { var y(get, never):Int; } "
			+ "class C implements I { public var y(get, never):Int; function get_y():Float return 3; } ",
			"Field get_y has different type than in I", "get_y():Float");
		expectError("an initializer", "interface I { var x:Int = 1; } ", "Initialization on field of interface",
			"1; }");
		expectError("a static", "interface I { static var x:Int; } ",
			"You can only declare static fields in extern interfaces", "static var");
		var implementation = "interface I { var y(get, never):Int; var x(default, null):Int; var s(never, set):Int; "
			+ "private var hidden:Int; } "
			+ "class C implements I { public var y(get, never):Int; function get_y() return 3; public var x:Int = 0; "
			+ "public var s(never, set):Int; function set_s(v) return v; public var hidden:Int = 0; public function new() {} } ";
		expectUseError("a write of a null side", implementation, "var i:I = new C(); i.x = 3;",
			"This expression cannot be accessed for writing", "x = 3");
		expectUseError("a write of a never side", implementation, "var i:I = new C(); i.y += 3;",
			"This expression cannot be accessed for writing", "y += 3");
		expectUseError("a read of a never side", implementation, "var i:I = new C(); var value:Int = i.s;",
			"This expression cannot be accessed for reading", "s;");
		expectUseError("a private variable from outside", implementation,
			"var i:I = new C(); var value:Int = i.hidden;",
			"Cannot access private field hidden", "hidden;");
		// An accessor the class declares privately implements the interface's, which Haxe adds to it.
		Frontend.compile(implementation + "function main():Int { var i:I = new C(); i.s = 1; return i.y + i.x; }");
		Sys.println("PASS: an interface's variables and properties are checked as Haxe checks them");
	}

	/** Expects `message` at the first occurrence of `at` in `declarations`. */
	static function expectError(label:String, declarations:String, message:String, at:String):Void
		expectUseError(label, declarations, "", message, at);

	/** Expects `message` at the first occurrence of `at` in `body`, else in `declarations`. */
	static function expectUseError(label:String, declarations:String, body:String, message:String, at:String):Void {
		var source = declarations + ' function main():Int { $body return 0; }';
		try {
			Frontend.compile(source);
		} catch (error:CompileError) {
			if (error.diagnostic.message != message)
				throw '$label: expected "$message", got ${error.diagnostic.format()}';
			var expected = source.indexOf(at, declarations.length);
			if (expected < 0)
				expected = source.indexOf(at);
			if (error.diagnostic.span.start != expected)
				throw '$label: expected the error at "$at" ($expected), got ${error.diagnostic.format()}';
			return;
		}
		throw '$label: the source was expected not to compile';
	}
}
