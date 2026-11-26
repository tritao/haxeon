using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.CompileOptions;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A warm build after an edit that changes what purity inference finds gives the bytes of a fresh build, with the reuse checks on:
 * a function whose body is not edited keeps what it was found to depend on only while the declarations its walk read are the same
 * (`compiler.semantic.ProgramPurity`), and the answers kept are what inference anew finds. Each edit leaves `Main` alone and changes something its walk asked about elsewhere: a
 * callee's body or its `@:pure`, a field it reads gaining a getter, a method it calls gaining an override, the initializer of a
 * class it constructs. A session of edits then moves answers both ways and back, through a cycle, a string conversion and an
 * abstract operator, which every answer depends on.
 */
class PurityWarmEditMain {
	static final boxSource =
		"class Box {
		public var v:Null<Int>;
		public var w:Int = 3;
		public function new() v = 1;
		public function twice():Int return w * 2;
	}";

	static final helperSource =
		"class Helper {
		public static function probe(b:Box):Int return b.w + 1;
		public static function make():Box return new Box();
	}";

	static final mainSource =
		"class Main {
		static function read(b:Box):Int {
			if (b.v != null) {
				Helper.probe(b);
				return b.v + b.twice();
			}
			return 0;
		}

		static function main():Int return read(Helper.make());
	}";

	static function initialSources():Map<String, String>
		return ["Box.hx" => boxSource, "Helper.hx" => helperSource, "Main.hx" => mainSource];

	static final cycleSource =
		"class Cycle {
		public static var log:Array<Int> = [];
		public static function even(n:Int):Bool return n == 0 ? true : odd(n - 1);
		public static function odd(n:Int):Bool return n == 0 ? false : even(n - 1);
		public static function tick():Int return 1;
	}";

	static final shownSource =
		"class Shown {
		public var w:Int = 0;
		public function new() {}
		public function get_w():Int {
			Cycle.log.push(0);
			return 0;
		}
		public function toString():String return \"shown\";
	}";

	static final metersSource =
		"abstract Meters(Int) from Int to Int { @:op(A - B) static function less(a:Meters, b:Meters):Meters return (a:Int) - (b:Int); }";

	static final cycleMainSource =
		"class Main {
		static function read(b:Box):Int {
			if (b.v != null) {
				Cycle.even(3);
				Helper.probe(b);
				var shown = \"\" + new Shown();
				var meters:Meters = 2;
				meters = meters - 1;
				return b.v + shown.length + meters;
			}
			return 0;
		}

		static function main():Int return read(Helper.make());
	}";

	static function main():Void {
		var failures:Array<String> = [];
		edit(failures, "a callee's body writes a field", files -> files.set("Helper.hx",
			StringTools.replace(helperSource, "return b.w + 1;", "{ b.v = null; return 0; }")));
		edit(failures, "a callee is declared pure", files -> files.set("Helper.hx",
			StringTools.replace(helperSource, "public static function probe", "@:pure public static function probe")));
		edit(failures, "a field the caller reads gains a getter", files -> files.set("Box.hx",
			StringTools.replace(boxSource, "public var w:Int = 3;",
			"public var w(get, never):Int; function get_w():Int { v = null; return 3; }")));
		edit(failures, "a method the caller calls gains an override", files -> files.set("Helper.hx", helperSource
			+ " class Loud extends Box { public function new() super(); override public function twice():Int { v = null; return 0; } }"));
		edit(failures, "a constructed class's initializer calls out", files -> files.set("Box.hx",
			StringTools.replace(boxSource, "public var w:Int = 3;", "public var w:Int = Sys.time() > 0 ? 3 : 4;")));
		var cycle = initialSources();
		cycle.set("Main.hx", cycleMainSource);
		cycle.set("Cycle.hx", cycleSource);
		cycle.set("Shown.hx", shownSource);
		cycle.set("Meters.hx", metersSource);
		session(failures, cycle, [{
			label: "a cycle's member writes a field",
			change: files -> files.set("Cycle.hx",
				StringTools.replace(cycleSource, "n == 0 ? false : even(n - 1);",
				"{ log.push(n); return n == 0 ? false : even(n - 1); }"))
		},
			{label: "the cycle's member is pure again", change: files -> files.set("Cycle.hx", cycleSource)},
			{
				label: "a cycle's member calls a function with an effect",
				change: files -> files.set("Cycle.hx",
					StringTools.replace(StringTools.replace(cycleSource, "public static function tick():Int return 1;",
					"public static function tick():Int { log.push(1); return 1; }"), "n == 0 ? true : odd(n - 1);",
					"n == 0 ? tick() > 0 : odd(n - 1);"))
			},
			{
				label: "the function the cycle calls loses its effect",
				change: files -> files.set("Cycle.hx",
					StringTools.replace(cycleSource, "n == 0 ? true : odd(n - 1);",
					"n == 0 ? tick() > 0 : odd(n - 1);"))
			},
			{
				label: "a string conversion writes a field",
				change: files -> files.set("Shown.hx",
					StringTools.replace(shownSource, "return \"shown\";", "{ Cycle.log.push(0); return \"shown\"; }"))
			},
			{
				label: "an abstract operator writes a field",
				change: files -> files.set("Meters.hx",
					StringTools.replace(metersSource, "return (a:Int) - (b:Int);",
					"{ Cycle.log.push(0); return (a:Int) - (b:Int); }"))
			},
			{label: "the operator and the conversion are pure again", change: files -> {
				files.set("Shown.hx", shownSource);
				files.set("Meters.hx", metersSource);
			}
		},
			{
				label: "a field another module's callee reads gains a getter",
				change: files -> files.set("Shown.hx",
					StringTools.replace(shownSource, "public var w:Int = 0;", "public var w(get, never):Int;"))
			},
			{
				label: "the field loses it",
				change: files -> files.set("Shown.hx", shownSource)
			},
			{
				label: "a cycle's member goes",
				change: files -> files.set("Cycle.hx",
					StringTools.replace(StringTools.replace(cycleSource,
					"public static function odd(n:Int):Bool return n == 0 ? false : even(n - 1);", ""), "odd(n - 1)",
					"even(n - 2)"))
			},
			{
				label: "the member is back",
				change: files -> files.set("Cycle.hx", cycleSource)
			}]);
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println("PASS: a warm build after an edit that changes purity equals a fresh one");
	}

	/** Builds the program, applies `change` in the same session and builds again; the warm module must be the fresh one's bytes. */
	static function edit(failures:Array<String>, label:String, change:Map<String, String>->Void):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files, true);
			compiler.compile("Main");
			change(files);
			for (path => text in files)
				compiler.update(path, text);
			var warm = compiler.compile("Main").artifact.hashLink().hashLinkBytes().flatten(),
				fresh = newCompiler(files, false).compile("Main").artifact.hashLink().hashLinkBytes().flatten();
			if (warm.compare(fresh) != 0)
				throw 'the warm module differs from a fresh one (${warm.length} and ${fresh.length} bytes)';
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}

	/** Builds `files`, then applies each change in turn in the same session; each warm module must be a fresh build's bytes. */
	static function session(failures:Array<String>, files:Map<String, String>,
			changes:Array<{label:String, change:Map<String, String>->Void}>):Void {
		var compiler = newCompiler(files, true);
		try {
			compiler.compile("Main");
		} catch (error:Dynamic) {
			failures.push("the session's first build: " + Std.string(error));
			return;
		}
		for (step in changes) {
			try {
				step.change(files);
				for (path => text in files)
					compiler.update(path, text);
				var warm = compiler.compile("Main").artifact.hashLink().hashLinkBytes().flatten(),
					fresh = newCompiler(files, false).compile("Main").artifact.hashLink().hashLinkBytes().flatten();
				if (warm.compare(fresh) != 0)
					throw 'the warm module differs from a fresh one (${warm.length} and ${fresh.length} bytes)';
			} catch (error:Dynamic) {
				failures.push('${step.label}: ${Std.string(error)}');
			}
		}
	}

	static function newCompiler(files:Map<String, String>, check:Bool):Compiler {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.livePatching = false;
		compiler.options = new CompileOptions({checkReuse: check});
		compiler.addSourceRoot("stdlib");
		for (path => text in files)
			compiler.update(path, text);
		return compiler;
	}
}
