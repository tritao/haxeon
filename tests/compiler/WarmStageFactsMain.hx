using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.CompileOptions;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A warm build after an edit that changes only a fact an IR stage reads about another function or declaration, and not the
 * function that reads it, gives the bytes of a fresh build. A per-function stage's memo (`IrStageQueries`) keeps the reader's
 * rewrite while the facts it read are unchanged (`IrStageFacts`), so each edit here leaves `Main`'s source as it is and changes one fact:
 * whether a callee is a nullable scalar candidate (`IrNullableScalarFlow`, the first and the last callee a reader asks about), the
 * form a value constructor expands to (`IrValueConstructors`), and whether an enum can be stored as its tag (`IrEnumTagLowering`).
 * Three edits change what such a fact describes along with the reader's IR or its lowering: a callee's arity (a call fills a new
 * optional argument), an enum tag that escapes to Dynamic (a release build then gives the enum a boxed descriptor, so the type
 * the lowering of its readers shares with Int parts from it), and a field's never-null status (which lowering reads).
 */
class WarmStageFactsMain {
	static final calcSource =
		"class Calc { public static function first(x:Null<Int>):Int return x == null ? 0 : x * 2; public static function last(x:Null<Int>):Int return x == null ? 1 : x + 1; }";

	/** The boxed copy makes the argument escape, so the callee is no longer a candidate. */
	static final escaping = "{ var boxed:Dynamic = x; return boxed == null ? 0 : 2; }";

	static final pairSource =
		"struct Pair { public var a:Int; public var b:Int; public function new(a:Int, b:Int) { this.a = a; this.b = b; } }";

	static final colorSource = "enum Color { Red; Green; Blue; }";
	static final leakSource =
		"class Leak { public static function hold():Int return 0; static function keep(value:Dynamic):Int return value == null ? 1 : 0; }";
	static final cellSource = "class Cell { public var item:String; public function new() item = \"cell\"; }";
	static final clearSource = "class Clear { public static function run(cell:Cell):Int return 0; }";

	static final mainSource =
		"class Main { static function main():Int return calls(3) + made(4) + pick(Red) + (same(Green) == Green ? 1 : 0) + Leak.hold() + size(new Cell()) + Clear.run(new Cell()); "
		+ "static function calls(v:Int):Int return Calc.first(v) + Calc.first(null) + Calc.last(v) + Calc.last(null); "
		+ "static function made(x:Int):Int { var p = new Pair(x, 2); return p.a + p.b; } "
		+ "static function pick(c:Color):Int return switch c { case Red: 1; case Green: 2; case Blue: 3; case _: 0; } "
		+ "static function same(c:Color):Color return c; "
		+ "static function size(cell:Cell):Int return cell.item.length; }";

	static function initialSources():Map<String, String>
		return [
			"Calc.hx" => calcSource,
			"Pair.hx" => pairSource,
			"Color.hx" => colorSource,
			"Leak.hx" => leakSource,
			"Cell.hx" => cellSource,
			"Clear.hx" => clearSource,
			"Main.hx" => mainSource
		];

	static function main():Void {
		var failures:Array<String> = [];
		edit(failures, "after the first callee a reader asks about stops being a nullable scalar candidate",
			files -> files.set("Calc.hx",
			StringTools.replace(calcSource, "return x == null ? 0 : x * 2;", escaping)));
		edit(failures, "after the last callee a reader asks about stops being a nullable scalar candidate",
			files -> files.set("Calc.hx",
			StringTools.replace(calcSource, "return x == null ? 1 : x + 1;", escaping)));
		edit(failures, "after a callee gains an optional nullable argument",
			files -> files.set("Calc.hx",
			StringTools.replace(calcSource, "first(x:Null<Int>)", "first(x:Null<Int>, ?y:Null<Int>)")));
		edit(failures, "after an edit of a value constructor a reader expands",
			files -> files.set("Pair.hx", StringTools.replace(pairSource, "this.b = b;", "this.b = b + 1;")));
		edit(failures, "after an enum a reader passes on gains a constructor with a payload",
			files -> files.set("Color.hx", StringTools.replace(colorSource, "Blue; }", "Blue; Mixed(level:Int); }")));
		edit(failures, "after an enum's tag escapes to a Dynamic argument in another module",
			files -> files.set("Leak.hx",
			StringTools.replace(leakSource, "hold():Int return 0;", "hold():Int return keep(Color.Green);")));
		edit(failures, "after another module stores null into a field a reader reads",
			files -> files.set("Clear.hx",
			StringTools.replace(clearSource, "return 0;", "{ cell.item = null; return 0; }")));
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println("PASS: a warm build after an edit of a fact a stage reads equals a fresh one");
	}

	/** An edit built warm in development and in release mode (which alone closes enum tags), each as it is and checking its reuse. */
	static function edit(failures:Array<String>, label:String, change:Map<String, String>->Void):Void {
		for (release in [false, true])
			for (check in [false, true])
				try {
					var files = initialSources(), compiler = newCompiler(files, release, check);
					compiler.compile("Main");
					change(files);
					if (files.get("Main.hx") != mainSource)
						throw "the edit changes the reader";
					for (path => text in files)
						compiler.update(path, text);
					compiler.addSourceRoot("stdlib");
					var warm = compiler.compile("Main"), fresh = newCompiler(files, release, false).compile("Main");
					if (StringTools.startsWith(warm.metrics.reuse, "ir"))
						throw 'the build reused "${warm.metrics.reuse}" after an edit';
					var warmBytes = warm.artifact.hashLink().hashLinkBytes().flatten(),
						freshBytes = fresh.artifact.hashLink().hashLinkBytes().flatten();
					if (warmBytes.compare(freshBytes) != 0)
						throw 'the warm module differs from a fresh one (${warmBytes.length} and ${freshBytes.length} bytes)';
				} catch (error:Dynamic) {
					failures.push(label + (release ? ", release" : "") + (check ? ", checked" : "") + ": "
						+ Std.string(error));
				}
	}

	/** Inlining is off, so no callee's body is copied into `Main`: what `Main` reads of its callees goes through the stages' facts. */
	static function newCompiler(files:Map<String, String>, release:Bool, check:Bool):Compiler {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.livePatching = false;
		compiler.developmentMetadata = !release;
		compiler.options = new CompileOptions({inlining: false, checkReuse: check});
		compiler.addSourceRoot("stdlib");
		for (path => text in files)
			compiler.update(path, text);
		return compiler;
	}
}
