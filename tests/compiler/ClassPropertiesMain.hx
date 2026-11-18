import compiler.Frontend;
import compiler.core.Diagnostic.CompileError;

/**
 * A class's instance properties are checked as Haxe 4.3.7 checks them, with its words and at its places: a `never` side cannot be
 * accessed, a `null` side only from the class and its subclasses, a `get` or `set` side needs its accessor and a `dynamic` one
 * that an access reaches (tests/differential/instance-properties*.hx run the accepted forms against it).
 */
class ClassPropertiesMain {
	static final ITEM = "class Item { public function new() {} "
		+ "public var area(get, never):Int; function get_area() return 1; "
		+ "public var sink(never, set):Int; function set_sink(value:Int) return value; "
		+ "public var hidden(null, default):Int = 0; "
		+ "public var fixed(default, null):Int = 0; "
		+ "public var loose(dynamic, dynamic):Int; } ";

	static function main():Void {
		for (write in ["item.area = 2;", "item.area += 2;", "++item.area;", "item.area++;"])
			expectError("a write of a never side: " + write, ITEM, "var item = new Item(); " + write,
				"This expression cannot be accessed for writing", "area");
		for (read in ["var value:Int = item.sink;", "item.sink += 1;", "item.sink++;"])
			expectError("a read of a never side: " + read, ITEM, "var item = new Item(); " + read,
				"This expression cannot be accessed for reading", "sink");
		expectError("a read of a null side from outside", ITEM, "var item = new Item(); var value:Int = item.hidden;",
			"This expression cannot be accessed for reading", "hidden;");
		expectError("a write of a null side from outside", ITEM, "var item = new Item(); item.fixed = 1;",
			"This expression cannot be accessed for writing", "fixed");
		expectError("a dynamic side without its accessor", ITEM, "var item = new Item(); var value:Int = item.loose;",
			"Could not resolve accessor", "item.loose");
		expectError("a missing getter", "class Item { public var area(get, never):Int; public function new() {} } ",
			"var item = new Item(); var value:Int = item.area;",
			"Method get_area required by property area is missing");
		expectError("a missing setter", "class Item { public var area(never, set):Int; public function new() {} } ", "",
			"Method set_area required by property area is missing");
		// Inside its own accessor a property is its variable, which a property with only accessors does not have.
		expectError("an accessor reading a property without storage",
			"class Item { public var area(get, never):Int; public function new() {} function get_area() return area + 1; } ",
			"",
			"This field cannot be accessed because it is not a real variable", "area + 1");
		Frontend.compile("class Item { @:isVar public var area(get, set):Int = 0; public function new() {} "
			+ "function get_area() return area; function set_area(value:Int) return area = value; } "
			+ "function main():Int { var item = new Item(); item.area = 2; return item.area; }");
		// An accessor a base class declares is the property's accessor, and a subclass may write a null side.
		Frontend.compile("class Base { public function new() {} function get_area() return 1; } "
			+ "class Item extends Base { public var area(get, null):Int; public function reset() area = 0; } "
			+ "function main():Int { var item = new Item(); item.reset(); return item.area; }");
		Sys.println("PASS: a class's instance properties are checked as Haxe checks them");
	}

	/** Expects `message`, at the first occurrence of `at` in `body`, else in `declarations`, when it is given. */
	static function expectError(label:String, declarations:String, body:String, message:String, ?at:String):Void {
		var source = declarations + ' function main():Int { $body return 0; }';
		try {
			Frontend.compile(source);
		} catch (error:CompileError) {
			if (error.diagnostic.message != message)
				throw '$label: expected "$message", got ${error.diagnostic.format()}';
			var expected = at == null ? -1 : source.indexOf(at, declarations.length);
			if (at != null && expected < 0)
				expected = source.indexOf(at);
			if (at != null && error.diagnostic.span.start != expected)
				throw '$label: expected the error at "$at" ($expected), got ${error.diagnostic.format()}';
			return;
		}
		throw '$label: the source was expected not to compile';
	}
}
