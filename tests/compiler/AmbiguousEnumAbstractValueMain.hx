import compiler.Compiler;

/**
 * A bare enum abstract value without an expected type is one of an abstract Haxe makes visible: its own module's, or an
 * imported one's (the last import wins, as with enum constructors). Two abstracts of the same module that declare the name
 * are an error that names them and says how to qualify the value; an abstract that is neither, its package's included,
 * does not put the name in scope.
 */
class AmbiguousEnumAbstractValueMain {
	static function main():Void {
		var first = [
			"p/First.hx",
			"package p; enum abstract First(Int) from Int to Int { var Red = 1; var Left = 3; }"
		],
			second = [
				"q/Second.hx",
				"package q; enum abstract Second(Int) from Int to Int { var Red = 2; var Right = 4; }"
			];

		// Neither abstract is imported: the name is not in scope.
		var foreign = failure([
			first,
			second,
			[
				"r/User.hx",
				"package r; class User { public static function pick():Int { var colour:Int = Red; return colour + p.First.Red + q.Second.Red; } }"
			],
			["Main.hx", "class Main { static function main():Int return r.User.pick(); }"]
		]);
		expect(foreign != null && foreign.indexOf('Unknown variable "Red"') >= 0,
			'a value of an abstract that is not imported must not be in scope, got: $foreign');

		// Imported, the abstracts' values are in scope, the last import's first.
		expect(failure([
			first,
			second,
			[
				"r/User.hx",
				"package r; import p.First; import q.Second; class User { public static function pick():Int { var colour:Int = Red; return colour + Left + Right; } }"
			],
			["Main.hx", "class Main { static function main():Int return r.User.pick(); }"]
		]) == null, "imported values must be in scope");

		// Two abstracts of the using module: ambiguous, and the error names both and how to qualify the value.
		var local = failure([
			[
				"r/User.hx",
				"package r; enum abstract Left(Int) from Int to Int { var Red = 1; } enum abstract Right(Int) from Int to Int { var Red = 2; } "
					+ "class User { public static function pick():Int { var colour:Int = Red; return colour + Left.Red + Right.Red; } }"
			],
			["Main.hx", "class Main { static function main():Int return r.User.pick(); }"]
		]);
		expect(local != null && local.indexOf('Ambiguous enum abstract value "Red"') >= 0
			&& local.indexOf('"r.Left"') >= 0
			&& local.indexOf('"r.Right"') >= 0, 'two abstracts of the module must be ambiguous and named, got: $local');
		expect(local.indexOf('"r.Left.Red"') >= 0, 'the error must show how to qualify the value, got: $local');

		// An abstract of the using package is not in scope without an import either; qualified values always are.
		var samePackage = failure([
			first,
			[
				"p/User.hx",
				"package p; class User { public static function pick():Int { var colour:Int = Red; return colour; } }"
			],
			["Main.hx", "class Main { static function main():Int return p.User.pick(); }"]
		]);
		expect(samePackage != null && samePackage.indexOf('Unknown variable "Red"') >= 0,
			'a same-package abstract must not put its values in scope, got: $samePackage');
		expect(failure([
			first,
			second,
			[
				"r/User.hx",
				"package r; class User { public static function pick():Int { var colour:Int = p.First.Red; return colour + q.Second.Red; } }"
			],
			["Main.hx", "class Main { static function main():Int return r.User.pick(); }"]
		]) == null, "qualified values must resolve");
		Sys.println("PASS: bare enum abstract values resolve only where they are visible, and ambiguities name their candidates");
	}

	/** The first diagnostic from analysing `Main` over the given files, or null when they analyse cleanly. */
	static function failure(files:Array<Array<String>>):Null<String> {
		var compiler = new Compiler();
		for (file in files)
			compiler.update(file[0], file[1]);
		try {
			compiler.analyze("Main");
			return null;
		} catch (error:Dynamic) {
			return Std.string(error).split("\n")[0];
		}
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
