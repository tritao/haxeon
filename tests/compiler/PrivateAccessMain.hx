import compiler.Compiler;
import compiler.Frontend;
import compiler.core.Diagnostic.CompileError;

/**
 * Haxe's `private`, checked where source names a member (MemberAccess): a member written without `public` is private to its class
 * and subclasses, unless `@:allow`, `@:access` or `@:privateAccess` grant it, or its owner makes members public by default (an
 * interface, an extern class, `@:publicFields`). The messages are stock Haxe's (checked with Haxe 4.3.7), reported at the access.
 */
class PrivateAccessMain {
	static final ITEM = 'class Item { var secret:Int = 1; static var count:Int = 0; public function new() {} '
		+ 'function hidden():Int return 2; static function make():Item return new Item(); '
		+ 'public function peek(other:Item):Int return other.secret + other.hidden(); } ';

	static function main():Void {
		// Reaching a private member from another class.
		expectPrivate(ITEM + 'function main():Int { var item = new Item(); return item.secret; }',
			"Cannot access private field secret",
			"item.secret");
		expectPrivate(ITEM + 'function main():Int { var item = new Item(); item.secret = 3; return 0; }',
			"Cannot access private field secret", "item.secret = 3");
		expectPrivate(ITEM + 'function main():Int { var item = new Item(); return item.hidden(); }',
			"Cannot access private field hidden", "item.hidden()");
		expectPrivate(ITEM + 'function main():Int { var item = new Item(); var f = item.hidden; return f(); }',
			"Cannot access private field hidden", "item.hidden;");
		expectPrivate(ITEM + 'function main():Int return Item.count;', "Cannot access private field count",
			"Item.count");
		expectPrivate(ITEM + 'function main():Int { Item.make(); return 0; }', "Cannot access private field make",
			"Item.make()");
		expectPrivate('class Hidden { function new() {} } function main():Int { new Hidden(); return 0; }',
			"Cannot access private constructor of Hidden", "new Hidden()");
		var abstractId = 'abstract Id(Int) { function new(value:Int) this = value; function raw():Int return this; '
			+ 'public static function of(value:Int):Id return new Id(value); public function read():Int return raw(); } ';
		expectPrivate(abstractId + 'function main():Int { new Id(1); return 0; }',
			"Cannot access private constructor of Id",
			"new Id(1)");
		expectPrivate(abstractId + 'function main():Int return Id.of(1).raw();', "Cannot access private field raw",
			"Id.of(1).raw()");
		expectPrivate('class Bag { public function new() {} function iterator():Iterator<Int> return [1].iterator(); } '
			+ 'function main():Int { var total = 0; for (value in new Bag()) total += value; return total; }',
			"Cannot access private field iterator", "new Bag()");
		// `@:allow` on another member grants only that member.
		expectPrivate('class Item { @:allow(Friend) var shared:Int = 1; var kept:Int = 2; public function new() {} } '
			+ 'class Friend { public static function read(item:Item):Int return item.kept; } '
			+ 'function main():Int return Friend.read(new Item());', "Cannot access private field kept", "item.kept");

		// What Haxe allows.
		Frontend.compile(ITEM + 'function main():Int { var item = new Item(); return item.peek(item); }');
		Frontend.compile(ITEM + 'class Child extends Item { public function new() super(); '
			+ 'public function read():Int return secret + hidden() + count + make().secret; } '
			+ 'function main():Int return new Child().read();');
		Frontend.compile(abstractId + 'function main():Int return Id.of(1).read();');
		Frontend.compile('@:allow(Friend) ' + ITEM + 'class Friend { public static function read(item:Item):Int '
			+ 'return item.secret + item.hidden() + Item.count + Item.make().secret; } function main():Int return Friend.read(new Item());');
		Frontend.compile('class Item { @:allow(Friend.read) var secret:Int = 1; public function new() {} } '
			+ 'class Friend { public static function read(item:Item):Int return item.secret; } '
			+ 'function main():Int return Friend.read(new Item());');
		Frontend.compile(ITEM
			+ '@:access(Item) class Friend { public static function read(item:Item):Int return item.secret; } '
			+ 'function main():Int return Friend.read(new Item());');
		Frontend.compile(ITEM
			+ 'class Friend { @:access(Item) public static function read(item:Item):Int return item.secret; } '
			+ 'function main():Int return Friend.read(new Item());');
		Frontend.compile(ITEM + 'function main():Int { var item = new Item(); return @:privateAccess item.secret; }');
		Frontend.compile('@:publicFields class Open { var value:Int = 1; function new() {} } '
			+ 'function main():Int return new Open().value;');
		Frontend.compile('interface Shape { function area():Int; } class Square implements Shape { public function new() {} '
			+ 'public function area():Int return 4; } function main():Int { var shape:Shape = new Square(); return shape.area(); }');
		// An override without a modifier has the overridden method's visibility; a class without a constructor of its own is
		// constructed through its base's, even a private one, as Haxe allows.
		Frontend.compile('class Base { public function new() {} public function value():Int return 1; } '
			+ 'class Derived extends Base { override function value():Int return 2; } '
			+ 'function main():Int return new Derived().value();');
		Frontend.compile('class Base { function new() {} } class Derived extends Base {} '
			+ 'function main():Int { new Derived(); return 0; }');
		warmEdits();
		Sys.println("PASS: private members are reached only where Haxe allows, with Haxe's messages");
	}

	/**
	 * A member made private, or public again, in a warm session is checked again in the modules that read it; a module's private
	 * variable is readable in its own module only.
	 */
	static function warmEdits():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		function item(visibility:String):String
			return 'package pkg; class Item { $visibility var value:Int = 1; $visibility function read():Int return value; '
				+ 'public function new() {} }';
		compiler.update("pkg/Item.hx", item("public"));
		compiler.update("Main.hx",
			"import pkg.Item; function main():Int { var item = new Item(); return item.value + item.read(); }");
		compiler.compile("Main");
		compiler.update("pkg/Item.hx", item("private"));
		expectCompileError(compiler, "Cannot access private field value", "private field after an edit");
		compiler.update("pkg/Item.hx", item("public"));
		compiler.compile("Main");
		compiler.update("pkg/Item.hx", item("public").split("public function read").join("function read"));
		expectCompileError(compiler, "Cannot access private field read", "private method after an edit");

		compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("pkg/Settings.hx", "package pkg; private var hits = 1; function count():Int return hits;");
		compiler.update("Main.hx", "import pkg.Settings; function main():Int return pkg.Settings.count();");
		compiler.compile("Main");
		compiler.update("Main.hx", "import pkg.Settings; function main():Int return pkg.Settings.hits;");
		expectCompileError(compiler, "Cannot access private field hits", "another module's private variable");
	}

	static function expectCompileError(compiler:Compiler, message:String, label:String):Void {
		try {
			compiler.compile("Main");
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1030" || error.diagnostic.message != message)
				throw '$label: expected E1030 "$message", got ${error.diagnostic.code} "${error.diagnostic.message}"';
			return;
		}
		throw '$label: expected "$message", but it compiled';
	}

	/** `source` fails to compile with E1030 and `message`, reported where `at` starts in the source. */
	static function expectPrivate(source:String, message:String, at:String):Void {
		try {
			Frontend.compile(source);
		} catch (error:CompileError) {
			var diagnostic = error.diagnostic, expectedStart = source.indexOf(at);
			if (diagnostic.code != "E1030" || diagnostic.message != message)
				throw 'Expected E1030 "$message", got ${diagnostic.code} "${diagnostic.message}" for: $source';
			if (diagnostic.span.start != expectedStart)
				throw 'Expected "$message" at "$at" (offset $expectedStart), got offset ${diagnostic.span.start}: '
					+ source.substr(diagnostic.span.start, 30);
			return;
		}
		throw 'Expected "$message", but it compiled: $source';
	}
}
