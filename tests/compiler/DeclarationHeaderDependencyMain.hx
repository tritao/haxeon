import compiler.Compiler;

/**
 * A type named only in a declaration header (a supertype, its type arguments, an abstract's underlying type or an abstract
 * method signature) loads its module. Each program's entry reaches the header's module but nothing else names the type,
 * as when an editor analyses a file importing `DesktopUiApplication`, which extends a same-package `UiApplication`.
 * Every program declares `ui.Derived`, which `Main` imports.
 */
class DeclarationHeaderDependencyMain {
	static final use = "class Main { static function use(value:Derived):Int return value.state(); public static function main():Int return 0; }";

	static function main():Void {
		expectAnalyzes("an interface extending a same-package interface", [
			"ui/Base.hx" => "package ui; interface Base { public function name():String; }",
			"ui/Derived.hx" => "package ui; interface Derived extends Base { public function state():Int; }"
		]);
		expectAnalyzes("an interface extending a fully qualified interface", [
			"core/Base.hx" => "package core; interface Base { public function name():String; }",
			"ui/Derived.hx" => "package ui; interface Derived extends core.Base { public function state():Int; }"
		]);
		expectAnalyzes("an interface extending a generic interface applied to a same-package type", [
			"ui/Listener.hx" => "package ui; interface Listener<T> { public function heard(value:T):Void; }",
			"ui/Event.hx" => "package ui; class Event { public function new() {} }",
			"ui/Derived.hx" => "package ui; interface Derived extends Listener<Event> { public function state():Int; }"
		]);
		expectAnalyzes("a class extending a generic class applied to a same-package type", [
			"ui/Box.hx" => "package ui; class Box<T> { public var value:Null<T>; public function new() {} }",
			"ui/Event.hx" => "package ui; class Event { public function new() {} }",
			"ui/Derived.hx" => "package ui; class Derived extends Box<Event> { public function new() super(); public function state():Int return 1; }"
		]);
		expectAnalyzes("a class implementing a generic interface applied to a same-package type", [
			"ui/Listener.hx" => "package ui; interface Listener<T> { public function heard(value:T):Void; }",
			"ui/Event.hx" => "package ui; class Event { public function new() {} }",
			"ui/Derived.hx" =>
			"package ui; class Derived implements Listener<Event> { public function new() {} public function heard(value:Event):Void {} public function state():Int return 1; }"
		]);
		expectAnalyzes("an abstract over a same-package class", [
			"ui/Inner.hx" => "package ui; class Inner { public function new() {} }",
			"ui/Derived.hx" =>
			"package ui; abstract Derived(Inner) { public inline function new(inner:Inner) this = inner; public function state():Int return 1; }"
		]);
		expectAnalyzes("an abstract method signature naming a same-package class", [
			"ui/Inner.hx" => "package ui; class Inner { public function new() {} }",
			"ui/Derived.hx" =>
			"package ui; abstract Derived(Int) { public inline function new(value:Int) this = value; public function state():Int return this; public function with(inner:Inner):Int return this; }"
		]);
		expectAnalyzes("an enum abstract over a same-package abstract", [
			"ui/Code.hx" => "package ui; abstract Code(Int) { public inline function new(value:Int) this = value; }",
			"ui/Derived.hx" => "package ui; enum abstract Derived(Code) { var First = cast 1; }"
		],
			"class Main { static function use(value:Derived):Int return 0; public static function main():Int return 0; }");
		Sys.println("PASS: types named only in declaration headers load their modules");
	}

	static function expectAnalyzes(description:String, sources:Map<String, String>, ?entry:String):Void {
		var compiler = new Compiler();
		for (path => source in sources)
			compiler.update(path, source);
		compiler.update("Main.hx", "import ui.Derived; " + (entry == null ? use : entry));
		try
			compiler.analyze("Main")
		catch (error:Dynamic)
			throw 'FAIL: $description did not load the module it names: ${Std.string(error)}';
	}
}
