import compiler.Compiler;

/**
 * A module that the program names only in a type position inside a function body must still be loaded: a local
 * variable's annotation (declared or uninitialised), a cast, or a catch clause. These are not references in an
 * expression, so the dependency scan used to skip them, and the type was reported as unknown unless something else in
 * the function happened to mention the module.
 */
class LocalTypeLoadMain {
	static function main():Void {
		var bodies = [
			"a local annotation" => "function f():Int { var h:Helper = One; return h; }",
			"an array annotation" => "function f():Int { var l:Array<Helper> = [One, One]; return l.length; }",
			"a nullable annotation" => "function f():Int { var h:Null<Helper> = One; return 0; }",
			"a map annotation" => "function f():Int { var m:Map<String, Helper> = [\"a\" => One]; return 0; }",
			"an uninitialised local" => "function f():Int { var h:Helper; h = One; return h; }",
			"a cast" => "function f():Int { var n = 1; var h = cast(n, Helper); return h; }",
			"a catch clause" => "function f():Int { try { return 1; } catch (e:Boom) { return 2; } }"
		];
		for (description => body in bodies) {
			var compiler = new Compiler();
			compiler.update("Helper.hx", "enum abstract Helper(Int) { var One = 1; }");
			compiler.update("Boom.hx", "class Boom { public function new() {} }");
			compiler.update("Main.hx", body + "\nfunction main():Int return 0;");
			try {
				compiler.analyze("Main");
			} catch (error:Dynamic) {
				throw 'A module named only in $description was not loaded: ${Std.string(error).split("\n")[0]}';
			}
		}
		// A sibling module's sub-type, named through the module (`Types.Kind`) only in a local annotation: the
		// dependency is the module that resolved (`pk.Types`), not the dotted type name, which names no module.
		var compiler = new Compiler();
		compiler.update("pk/Types.hx", "package pk; class Types {} enum abstract Kind(Int) { var One = 1; }");
		compiler.update("pk/User.hx", "package pk; class User { public static function f():Int { var k:Types.Kind = cast 1; return 0; } }");
		compiler.update("Main.hx", "import pk.User;\nfunction main():Int return User.f();");
		try {
			compiler.analyze("Main");
		} catch (error:Dynamic) {
			throw 'A module named through its package only in a local annotation was not loaded: ${Std.string(error).split("\n")[0]}';
		}
		Sys.println("PASS: modules named only in a local type annotation, cast or catch clause are loaded");
	}
}
