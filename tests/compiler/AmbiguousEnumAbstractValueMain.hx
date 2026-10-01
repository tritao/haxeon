import compiler.Compiler;

/**
 * Two enum abstracts over the same type that declare a value name compete for a bare reference to it. The one
 * in the current package wins (see SamePackageEnumAbstractValueMain); when that leaves none or several, the
 * reference is an error that names the abstracts and says how to qualify the value.
 */
class AmbiguousEnumAbstractValueMain {
	static function main():Void {
		var first = [
			"p/First.hx",
			"package p; enum abstract First(Int) { var Red = 1; var Left = 3; }"
		], second = [
			"q/Second.hx",
			"package q; enum abstract Second(Int) { var Red = 2; var Right = 4; }"
			];

		// Neither abstract is in the using package: ambiguous, and the error lists both.
		var foreign = failure([
			first,
			second,
			[
				"r/User.hx",
				"package r; class User { public static function pick():Int { var colour:Int = Red; return colour + p.First.Red + q.Second.Red; } }"
			],
			["Main.hx", "class Main { static function main():Int return r.User.pick(); }"]
		]);
		expect(foreign != null && foreign.indexOf("E1005") >= 0 && foreign.indexOf('Ambiguous enum abstract value "Red"') >= 0,
			'a bare value declared by two foreign enum abstracts must be ambiguous, got: $foreign');
		expect(foreign.indexOf('"p.First"') >= 0 && foreign.indexOf('"q.Second"') >= 0, 'the error must name both abstracts, got: $foreign');
		expect(foreign.indexOf("none of them is in the current package") >= 0, 'the error must say no abstract is in the current package, got: $foreign');
		expect(foreign.indexOf('"p.First.Red"') >= 0, 'the error must show how to qualify the value, got: $foreign');

		// Two abstracts in the using package: the same-package rule cannot choose either.
		var local = failure([
			["r/Left.hx", "package r; enum abstract Left(Int) { var Red = 1; }"],
			["r/Right.hx", "package r; enum abstract Right(Int) { var Red = 2; }"],
			[
				"r/User.hx",
				"package r; class User { public static function pick():Int { var colour:Int = Red; return colour + Left.Red + Right.Red; } }"
			],
			["Main.hx", "class Main { static function main():Int return r.User.pick(); }"]
		]);
		expect(local != null && local.indexOf('"r.Left"') >= 0 && local.indexOf('"r.Right"') >= 0,
			'two same-package enum abstracts must be ambiguous and named, got: $local');
		expect(local.indexOf("more than one of them is in the current package") >= 0, 'the error must say several are in the current package, got: $local');

		// Qualifying the value, or declaring one abstract in the using package, removes the ambiguity.
		expect(failure([
			first,
			second,
			[
				"r/User.hx",
				"package r; class User { public static function pick():Int { var colour:Int = p.First.Red; return colour + q.Second.Red; } }"
			],
			["Main.hx", "class Main { static function main():Int return r.User.pick(); }"]
		]) == null, "qualified values must not be ambiguous");
		expect(failure([
			first,
			second,
			[
				"p/User.hx",
				"package p; class User { public static function pick():Int { var colour:Int = Red; return colour + q.Second.Red; } }"
			],
			["Main.hx", "class Main { static function main():Int return p.User.pick(); }"]
		]) == null, "an enum abstract in the using package must outrank the one elsewhere");
		Sys.println("PASS: ambiguous enum abstract values are reported with their candidates and a qualification hint");
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
