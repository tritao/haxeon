import compiler.Compiler;

/**
 * A generic function whose body depends on another class's layout is invalidated when that layout changes, and its
 * cached specializations are dropped with it. A caller that was not edited still needs them, so it must be retyped too.
 */
class GenericStructuralMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Shape.hx", "class Shape { public var a:Int; public function new() { a = 1; } }");
		compiler.update("Reader.hx",
			"class Reader { public var shape:Shape; public var count:Int; public function new() { shape = new Shape(); count = 0; } " +
			"public function read<T>(value:T, create:Void->T):Int { count++; var made = create(); return count + (made == null ? 0 : 1); } }");
		compiler.update("Main.hx",
			"function main():Int { var reader = new Reader(); return reader.read(5, function() return 6) + reader.read(\"s\", function() return \"t\") + (function() return reader.read(1.5, function() return 2.5))(); }");
		compiler.compile("Main");
		compiler.update("Shape.hx", "class Shape { public var b:Int; public var a:Int; public function new() { a = 1; b = 2; } }");
		var result = compiler.compile("Main");
		var specializations = 0;
		for (name in result.functionIndices.keys())
			if (name.indexOf("generic:Reader.read") >= 0)
				specializations++;
		if (specializations != 3)
			throw 'Expected all three Reader.read specializations (one requested only from a lambda) after a layout change, found $specializations';
		// Editing the generic body drops its specializations the same way; the callers are found from their lowered bodies.
		compiler.update("Reader.hx",
			"class Reader { public var shape:Shape; public var count:Int; public function new() { shape = new Shape(); count = 0; } " +
			"public function read<T>(value:T, create:Void->T):Int { count += 2; var made = create(); return count + (made == null ? 0 : 1); } }");
		result = compiler.compile("Main");
		specializations = 0;
		for (name in result.functionIndices.keys())
			if (name.indexOf("generic:Reader.read") >= 0)
				specializations++;
		if (specializations != 3)
			throw 'Expected all three Reader.read specializations after a body edit, found $specializations';
		Sys.println("PASS: specializations survive a structural change of their origin's dependency");
	}
}
