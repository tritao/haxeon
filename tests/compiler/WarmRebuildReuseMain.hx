import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import haxe.io.Bytes;

/**
 * A plain build in a reused compiler session gives the bytes of a fresh build of the same sources, and when nothing the IR pipeline
 * reads changed it does so without running a pass or lowering a function (`metrics.reuse`).
 *
 * The program has a generic class (`Box`), an enum (`Shape`), a library module and a user of both. Every scenario compiles it once,
 * applies an edit in the same session, compiles again, and compares the module with a fresh compiler's. An edit that changes the
 * program must not report a reused module; a build with no edit must. With HAXEON_CHECK_REUSE=1 the reused result is also assembled again
 * and compared inside the compiler, which throws on a difference.
 */
class WarmRebuildReuseMain {
	static final boxSource = "class Box<T> { public var value:T; public function new(value:T) this.value = value; public function get():T return value; }";
	static final shapeSource = "enum Shape { Circle(radius:Int); Square(side:Int); }";
	static final areaSource = "class Area { public static function of(shape:Shape):Int return switch shape { case Circle(radius): 3 * radius * radius; case Square(side): side * side; }; }";
	static final libSource = "class Lib { public static function add(a:Int, b:Int):Int return a + b; public static function name():String return \"lib\"; public static function boxed():Int return new Box<Int>(3).get(); }";

	/** Field initializers register anonymous types (`{}`) when they are typed, which a warm build does not do again for an unchanged class. */
	static final configSource = "class Config { public static var empty:Dynamic = {}; public var data:Dynamic = {a: 1}; public function new() {} }";

	static final mainSource = "class Main { static function main():Int { var total = Lib.add(1, 2) + Lib.boxed() + Area.of(Circle(2)); return total == 18 && Lib.name().length == 3 && new Config().data != null && Config.empty != null ? 42 : 1; } }";

	static function initialSources():Map<String, String>
		return [
			"Box.hx" => boxSource,
			"Shape.hx" => shapeSource,
			"Area.hx" => areaSource,
			"Lib.hx" => libSource,
			"Config.hx" => configSource,
			"Main.hx" => mainSource
		];

	static function main():Void {
		var failures:Array<String> = [];
		attempt(failures, "second build without an edit", true, files -> {});
		attempt(failures, "second build without an edit, checked", true, files -> {}, true);
		edit(failures, "after a body edit", files -> files.set("Lib.hx", StringTools.replace(libSource, "return a + b;", "return a + b + 0;")));
		edit(failures, "after a signature edit",
			files -> files.set("Lib.hx", StringTools.replace(libSource, "add(a:Int, b:Int)", "add(a:Int, b:Int, c:Int = 0)")));
		edit(failures, "after a new generic specialization", files -> {
			files.set("Lib.hx",
				StringTools.replace(libSource, "return new Box<Int>(3).get();", "return new Box<Int>(3).get() + new Box<String>(\"x\").get().length - 1;"));
		});
		edit(failures, "after adding a function",
			files -> files.set("Lib.hx",
				StringTools.replace(libSource, "public static function name()", "public static function extra():Int return 7; public static function name()")));
		edit(failures, "after removing a module", files -> {
			files.remove("Area.hx");
			files.set("Main.hx", StringTools.replace(mainSource, " + Area.of(Circle(2))", " + 12"));
		});
		edit(failures, "after a new constant in a function early in the layout, which shifts the constant tables of the functions after it",
			files -> files.set("Area.hx", StringTools.replace(areaSource, "3 * radius * radius", "3 * radius * radius + 123456789")), true);
		edit(failures, "after a new function early in the layout, which shifts the function indices of the functions after it",
			files -> files.set("Area.hx",
				StringTools.replace(areaSource, "public static function of(",
					"public static function again(shape:Shape):Int return 7; public static function of(")),
			true);
		edit(failures, "after a new string constant",
			files -> files.set("Lib.hx",
				StringTools.replace(libSource, "return \"lib\";",
					"return \"lib\";" + " public static function shifted():String return \"a-constant-that-shifts-the-string-table\";")));
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println("PASS: a warm plain build equals a fresh one, and reuses its module when nothing changed");
	}

	/** An edit is built in a warm session twice: as it is, and with HAXEON_CHECK_REUSE=1, which also lowers every function afresh and compares. */
	static function edit(failures:Array<String>, label:String, change:Map<String, String>->Void, shifts:Bool = false):Void {
		attempt(failures, label, false, change, false, shifts);
		attempt(failures, label + ", checked", false, change, true, shifts);
	}

	static function attempt(failures:Array<String>, label:String, expectReuse:Bool, change:Map<String, String>->Void, ?check:Bool = false,
			?shifts:Bool = false):Void {
		var checkBefore = Sys.getEnv("HAXEON_CHECK_REUSE");
		try {
			Sys.putEnv("HAXEON_CHECK_REUSE", check ? "1" : "0");
			var files = initialSources(), compiler = newCompiler(files);
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
			var warmBytes = HlWriter.encode(warm.module).flatten(),
				freshBytes = HlWriter.encode(fresh.module).flatten();
			if (warmBytes.compare(freshBytes) != 0)
				throw 'the warm module differs from a fresh one (${warmBytes.length} and ${freshBytes.length} bytes)';
			if (expectReuse && !check && warm.module != first.module)
				throw "a reused build did not return the earlier module";
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
		Sys.putEnv("HAXEON_CHECK_REUSE", checkBefore == null ? "0" : checkBefore);
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
