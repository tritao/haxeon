using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.CompileOptions;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A warm build after an edit that changes what purity inference finds gives the bytes of a fresh build, with the reuse checks on:
 * a function whose body is not edited keeps what it was found to depend on only while the declarations its walk read are the same
 * (`PurityInference.PurityDependencies`). Each edit leaves `Main` alone and changes something its walk asked about elsewhere: a
 * callee's body or its `@:pure`, a field it reads gaining a getter, a method it calls gaining an override, the initializer of a
 * class it constructs.
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
