import compiler.Frontend;
import compiler.core.Diagnostic.CompileError;

/**
 * Abstract classes, as Haxe 4.2 has them: an `abstract class` is never constructed itself, its `abstract function`s have no
 * body and every concrete subclass writes them, and a subclass writes one without `override`
 * (tests/programs/abstract-classes.hx runs the accepted forms).
 */
class AbstractClassesMain {
	static final SHAPE = "abstract class Shape { public function new() {} public abstract function area():Int; "
		+ "public function twice():Int return area() * 2; } ";

	static function main():Void {
		expectError("constructing an abstract class", SHAPE, "var shape = new Shape();",
			'Class "Shape" is abstract: construct one of its subclasses', "new Shape");
		expectError("a concrete subclass without the method", SHAPE + "class Square extends Shape {} ", "",
			'Class "Square" must write abstract method "Shape.area"', "class Square");
		expectError("an abstract method declared again lower down",
			SHAPE + "class Square extends Shape { public function area():Int return 4; } "
			+ "abstract class Tile extends Square { public abstract function area():Int; } class Floor extends Tile {} ",
			"", 'Class "Floor" must write abstract method "Tile.area"', "class Floor");
		expectError("super calling an abstract method",
			SHAPE + "class Square extends Shape { public function area():Int return super.area(); } ", "",
			'Cannot call super.area: "Shape.area" is abstract', "super.area");
		expectError("an abstract method in a concrete class", "class Shape { public abstract function area():Int; } ",
			"", 'Class "Shape" has an abstract method, so it must be declared abstract class', "public abstract");
		expectError("an abstract method with a body",
			"abstract class Shape { public abstract function area():Int return 1; } ", "",
			"Expected Semicolon, got Return",
			"return 1");
		expectError("an abstract method without its return type", "abstract class Shape { abstract function area(); } ",
			"", 'Abstract method "area" needs its return type written');
		expectError("a static abstract method", "abstract class Shape { static abstract function area():Int; } ", "",
			"An abstract method cannot be static, inline, final, dynamic or extern", "static abstract");
		expectError("an abstract field", "abstract class Shape { abstract var area:Int; } ", "",
			"Only a method can be abstract", "var area");
		// Written once, lower down: every class below has it.
		Frontend.compile(SHAPE
			+ "abstract class Tile extends Shape {} class Square extends Tile { public function new() "
			+ "super(); public function area():Int return 4; } class Small extends Square {} "
			+ "function main():Int return new Small().twice();");
		// A member named abstract is not the modifier.
		Frontend.compile("class Names { public var abstract:Int = 1; public function new() {} } "
			+ "function main():Int return new Names().abstract;");
		Sys.println("PASS: abstract classes are never constructed, and their subclasses write their abstract methods");
	}

	/** Expects `message`, at the first occurrence of `at` in the source, when it is given. */
	static function expectError(label:String, declarations:String, body:String, message:String, ?at:String):Void {
		var source = declarations + ' function main():Int { $body return 0; }';
		try {
			Frontend.compile(source);
		} catch (error:CompileError) {
			if (error.diagnostic.message != message)
				throw '$label: expected "$message", got ${error.diagnostic.format()}';
			if (at != null && error.diagnostic.span.start != source.indexOf(at))
				throw '$label: expected the error at "$at" (${source.indexOf(at)}), got ${error.diagnostic.format()}';
			return;
		}
		throw '$label: the source was expected not to compile';
	}
}
