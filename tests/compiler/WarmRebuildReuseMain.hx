using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.CompileOptions;
import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;

/**
 * A plain build in a reused compiler session gives the bytes of a fresh build of the same sources, and when nothing the IR pipeline
 * reads changed it does so without running a pass or lowering a function (`metrics.reuse`).
 *
 * The program has a generic class (`Box`), an enum (`Shape`), an enum abstract (`Level`), a library module and a user of them. Every scenario compiles it once,
 * applies an edit in the same session, compiles again, and compares the module with a fresh compiler's. An edit that changes the
 * program must not report a reused module; a build with no edit must. A compile that checks its reuse also assembles the reused result again
 * and compared inside the compiler, which throws on a difference.
 */
class WarmRebuildReuseMain {
	static final boxSource =
		"class Box<T> { public var value:T; public var spare:Int; public function new(value:T) this.value = value; public function get():T return value; }";
	static final shapeSource = "enum Shape { Circle(radius:Int); Square(side:Int); }";
	static final levelSource = "enum abstract Level(Int) to Int { var Low = 1; var High = 2; }";

	/** `step` is recursive so it is not inlined into `of` or `main`: a function nothing reaches is not in the module, and the scenarios below edit functions that are. */
	static final areaSource =
		"class Area { public static function of(shape:Shape):Int return step(shape, 0); static function step(shape:Shape, n:Int):Int return n > 0 ? step(shape, n - 1) : switch shape { case Circle(radius): 3 * radius * radius; case Square(side): side * side; }; }";

	static final libSource =
		"class Lib { public static function add(a:Int, b:Int):Int return a + b; public static function name():String return \"lib\"; public static function boxed():Int return new Box<Int>(3).get(); }";

	/** Field initializers register anonymous types (`{}`) when they are typed, which a warm build does not do again for an unchanged class. */
	static final configSource =
		"class Config { public static var empty:Dynamic = {}; public var data:Dynamic = {a: 1}; public function new() {} }";

	/** An anonymous type that only an optional parameter's element type names, which no body constructs. */
	static final encoderSource =
		"class Encoder { public static function encode(value:Int, ?sections:Array<{tag:Int, name:String}>):Int return sections == null ? value : value + sections.length; }";

	/**
	 * An abstract member nothing calls is typed to be checked, and the structural iterator it returns is not part of the program:
	 * a warm build that does not check it again lists the anonymous types a fresh one does.
	 */
	static final trailSource =
		"enum Step { Walk(n:Int); Stop; } abstract Trail(Array<Step>) from Array<Step> { public static function size(steps:Array<Step>):Int return steps.length; public function iterator():Iterator<Step> return this.iterator(); }";

	/**
	 * Bodies another module reads: an inline function expands in its caller, with the private functions it calls, and a generic
	 * function is specialized for its caller. Editing only a private helper behind them must change the caller as a fresh build does.
	 */
	static final opsSource =
		"class Ops { public static inline function twice(x:Int):Int return step(x) * 2 + bump(x); static inline function step(x:Int):Int return x + 1; static function bump(x:Int):Int return x + 3; public static function first<T>(xs:Array<T>):T return pick(xs); static function pick<T>(xs:Array<T>):T return xs[0]; }";

	static final mainSource =
		"class Main { static function main():Int { var total = Lib.add(1, 2) + Lib.boxed() + Area.of(Circle(2)) + Level.High; return total == 20 && Lib.name().length == 3 && new Config().data != null && Config.empty != null && Encoder.encode(0) == 0 && Trail.size([Stop]) == 1 && Ops.twice(3) > 0 && Ops.first([5, 6]) > 0 ? 42 : 1; } }";

	static function initialSources():Map<String, String>
		return [
			"Box.hx" => boxSource,
			"Shape.hx" => shapeSource,
			"Level.hx" => levelSource,
			"Area.hx" => areaSource,
			"Lib.hx" => libSource,
			"Config.hx" => configSource,
			"Encoder.hx" => encoderSource,
			"Trail.hx" => trailSource,
			"Ops.hx" => opsSource,
			"Main.hx" => mainSource
		];

	static function main():Void {
		var failures:Array<String> = [];
		attempt(failures, "second build without an edit", true, files -> {});
		attempt(failures, "second build without an edit, checked", true, files -> {}, true);
		edit(failures, "after a body edit",
			files -> files.set("Lib.hx", StringTools.replace(libSource, "return a + b;", "return a + b + 0;")));
		edit(failures, "after a signature edit",
			files -> files.set("Lib.hx",
			StringTools.replace(libSource, "add(a:Int, b:Int)", "add(a:Int, b:Int, c:Int = 0)")));
		edit(failures, "after a new generic specialization", files -> {
			files.set("Lib.hx",
				StringTools.replace(libSource, "return new Box<Int>(3).get();",
				"return new Box<Int>(3).get() + new Box<String>(\"x\").get().length - 1;"));
		});
		edit(failures, "after adding a function",
			files -> files.set("Lib.hx",
			StringTools.replace(libSource, "public static function name()",
			"public static function extra():Int return 7; public static function name()")));
		edit(failures, "after removing a module", files -> {
			files.remove("Area.hx");
			files.set("Main.hx", StringTools.replace(mainSource, " + Area.of(Circle(2))", " + 12"));
		});
		edit(failures,
			"after a new constant in a function early in the layout, which shifts the constant tables of the functions after it",
			files -> files.set("Box.hx",
			StringTools.replace(boxSource, "public function get():T return value;",
			"public function get():T { spare = spare + 123456789; return value; }")),
			true);
		edit(failures,
			"after a new function early in the layout, which shifts the function indices of the functions after it",
			files -> {
				files.set("Area.hx",
					StringTools.replace(areaSource, "public static function of(",
					"public static function again(shape:Shape, n:Int):Int return n > 0 ? again(shape, n - 1) : 7; public static function of("));
				files.set("Main.hx", StringTools.replace(mainSource, "Area.of(Circle(2))",
					"Area.of(Circle(2)) + Area.again(Circle(1), 0) - 7"));
			}, true);
		edit(failures, "after a new string constant",
			files -> files.set("Lib.hx",
			StringTools.replace(libSource, "return \"lib\";",
			"return \"lib\";"
			+ " public static function shifted():String return \"a-constant-that-shifts-the-string-table\";")));
		// A reader inlines an enum abstract's value where the value is declared, so moving the declaration retypes the reader.
		edit(failures, "after an enum abstract moved down its file",
			files -> files.set("Level.hx", "\n\n" + levelSource));
		edit(failures, "after an edit of a private inline function an inline function expands into",
			files -> files.set("Ops.hx", StringTools.replace(opsSource, "return x + 1;", "return x + 2;")));
		edit(failures, "after an edit of a private function an inline function calls",
			files -> files.set("Ops.hx", StringTools.replace(opsSource, "return x + 3;", "return x + 4;")));
		edit(failures, "after an edit of a private generic function a generic function calls",
			files -> files.set("Ops.hx", StringTools.replace(opsSource, "return xs[0];", "return xs[xs.length - 1];")));
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println("PASS: a warm plain build equals a fresh one, and reuses its module when nothing changed");
	}

	/** An edit is built in a warm session twice: as it is, and checking its reuse, which also lowers every function afresh and compares. */
	static function edit(failures:Array<String>, label:String, change:Map<String, String>->Void,
			shifts:Bool = false):Void {
		attempt(failures, label, false, change, false, shifts);
		attempt(failures, label + ", checked", false, change, true, shifts);
	}

	static function attempt(failures:Array<String>, label:String, expectReuse:Bool, change:Map<String, String>->Void,
			?check:Bool = false,
			?shifts:Bool = false):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			compiler.options = new CompileOptions({checkReuse: check});
			var first = compiler.compile("Main");
			var before = [for (path in files.keys()) path];
			change(files);
			for (path => text in files)
				compiler.update(path, text);
			for (path in before)
				if (!files.exists(path))
					compiler.remove(path);
			// A session that is asked to build again registers its source roots again, which is what makes the compiler build rather than
			// return its last result.
			compiler.addSourceRoot("stdlib");
			var warm = compiler.compile("Main"),
				freshCompiler = newCompiler(files),
				fresh = freshCompiler.compile("Main");
			var reuse = warm.metrics.reuse;
			// A checked build assembles the module again to compare it, so it reports the IR as the only reused part.
			var wanted = expectReuse ? (check ? "ir" : "ir+module") : null;
			if (expectReuse && reuse != wanted)
				throw 'expected reuse "$wanted" but the build reported "$reuse"';
			if (!expectReuse && StringTools.startsWith(reuse, "ir"))
				throw 'the build reused "$reuse" after an edit';
			if (shifts && warm.metrics.movedFunctions == 0)
				throw "the edit shifts the tables but no linked function was given other indices";
			if (!expectReuse && warm.metrics.linkedFunctions == 0)
				throw "no function was linked from the last build's lowering after an edit";
			var warmTypes = anonymousTypes(compiler),
				freshTypes = anonymousTypes(freshCompiler);
			if (warmTypes != freshTypes)
				throw 'the warm typed program lists other anonymous types than a fresh one\nwarm:  $warmTypes\nfresh: $freshTypes';
			var warmBytes = HlWriter.encode(warm.artifact.hashLink().module).flatten(),
				freshBytes = HlWriter.encode(fresh.artifact.hashLink().module).flatten();
			if (warmBytes.compare(freshBytes) != 0)
				throw 'the warm module differs from a fresh one (${warmBytes.length} and ${freshBytes.length} bytes)';
			if (expectReuse && !check && warm.artifact.hashLink().module != first.artifact.hashLink().module)
				throw "a reused build did not return the earlier module";
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}

	/** The names of the anonymous types of the last typed program, sorted: a warm program lists what a fresh one does. */
	static function anonymousTypes(compiler:Compiler):String {
		var program = compiler.lastTypedProgram;
		if (program == null)
			throw "no typed program";
		return [for (entry in program.anonymousTypes) entry.name].join("\n");
	}

	static function newCompiler(files:Map<String, String>):Compiler {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.livePatching = false;
		compiler.addSourceRoot("stdlib");
		for (path => text in files)
			compiler.update(path, text);
		return compiler;
	}
}
