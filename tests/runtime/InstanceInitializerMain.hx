import compiler.Compiler;

class InstanceInitializerMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", "class Box { public var value:Int = 40; } function main():Int { return new Box().value; }");
		var first = compiler.compile("Main");
		if (!first.functionIndices.exists("Box.new"))
			throw "Implicit constructor was not generated for an instance initializer";
		compiler.update("Main.hx", "class Box { public var value:Int; } function main():Int { return new Box().value; }");
		var changed = compiler.compile("Main");
		if (changed.functionIndices.exists("Box.new"))
			throw "Removed instance initializer left a stale implicit constructor";
		compiler.update("Main.hx", "class Box { public var value:Int = 41; } function main():Int { return new Box().value; }");
		var added = compiler.compile("Main");
		if (!added.functionIndices.exists("Box.new"))
			throw "Added instance initializer did not restore the implicit constructor";
		Sys.println("PASS: instance initializer constructor invalidation");
	}
}
