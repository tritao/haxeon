import compiler.Compiler;

/**
 * "Returns on every path" follows Haxe: a switch ending in the wildcard arm `case _:` (or a bare name) has a default,
 * and a bare block `{ ... }` runs its body, so either of them can be what makes a function return. A switch with
 * neither a default nor an exhaustive enum, and an `if` without an `else`, still fall through.
 */
class ReturnPathMain {
	static function main():Void {
		var returning = [
			"an Int switch ending in case _" => "function build(n:Int):String { switch n { case 1: return \"one\"; case _: return \"many\"; } }",
			"an Int switch ending in a bare name" => "function build(n:Int):Int { switch n { case 1: return 1; case other: return other; } }",
			"an enum switch ending in case _" => "function build(k:Kind):Int { switch k { case A: return 1; case _: return 2; } }",
			"an enum switch that covers every constructor" =>
			"function build(k:Kind):Int { switch k { case A: return 1; case B: return 2; case C: return 3; } }",
			"an Int switch with a default" => "function build(n:Int):Int { switch n { case 1: return 1; default: return 2; } }",
			"a switch whose arms are blocks" => "function build(n:Int):Int { switch n { case 1: { return 1; } case _: { var x = 2; return x; } } }",
			"a plain block that returns" => "function build(n:Int):Int { { return 1; } }",
			"a block after other statements" => "function build(n:Int):Int { var y = 1; { var x = 2; return x + y; } }",
			"nested switches" =>
			"function build(k:Kind, n:Int):Int { switch k { case A: switch n { case 1: return 1; case _: return 2; } case _: return 3; } }",
			"an arm that throws" => "function build(k:Kind):Int { switch k { case A: return 1; case _: throw \"no\"; } }",
			"a guarded arm followed by a catch-all" =>
			"function build(k:Kind, n:Int):Int { switch k { case A if (n > 0): return 1; case A: return 2; case _: return 3; } }"
		];
		for (description => source in returning)
			expect(analyse(source) == null, 'A function with $description must return on every path, got: ${analyse(source)}');
		var falling = [
			"an Int switch without a default" => "function build(n:Int):String { switch n { case 1: return \"one\"; case 2: return \"two\"; } }",
			"a switch whose only catch-all has a guard" => "function build(n:Int):Int { switch n { case 1: return 1; case other if (other > 5): return 2; } }",
			"a switch with an arm that does not return" => "function build(n:Int):Int { var x = 0; switch n { case 1: x = 1; case _: return 2; } }",
			"an if without an else" => "function build(n:Int):Int { if (n > 0) { return 1; } }",
			"a block that does not return" => "function build(n:Int):Int { { var x = n; } }",
			"a block that returns only on one branch" => "function build(n:Int):Int { { if (n > 0) return 1; } }"
		];
		for (description => source in falling) {
			var message = analyse(source);
			expect(message != null && message.indexOf("does not return on every path") >= 0,
				'A function with $description must not return on every path, got: $message');
		}
		Sys.println("PASS: switches ending in a wildcard arm and bare blocks return on every path");
	}

	/** The first diagnostic from analysing `source` with an enum `Kind`, or null when it analyses cleanly. */
	static function analyse(source:String):Null<String> {
		var compiler = new Compiler();
		compiler.update("Kind.hx", "enum Kind { A; B; C; }");
		compiler.update("Main.hx", source + "\nfunction main():Int return 0;");
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
