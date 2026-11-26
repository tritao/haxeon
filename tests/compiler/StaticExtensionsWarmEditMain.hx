using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A warm build after the static extensions a module sees change gives the bytes of a fresh build of the same sources. Main's calls
 * read the same before and after each edit, but what they resolve to (`StaticExtensions`) follows modules Main never names in its
 * bodies: an extension a later `using` gains wins over the one the call reached, one it loses gives the call back to the earlier
 * `using`, and a type's `@:using` gains or loses one too.
 */
class StaticExtensionsWarmEditMain {
	static final toolsSource =
		"class Tools {
		public static function shout(s:String):String return s + \"!\";
		public static function size(shape:Shape):Int return 1;
	}";

	static final laterSource = "class Later {
		public static function twice(x:Int):Int return x * 2;
	}";

	static final shapeSource = "@:using(ShapeTools) enum Shape { Dot; Line(length:Int); }";

	static final shapeToolsSource = "class ShapeTools {
		public static function width(shape:Shape):Int return 2;
	}";

	static final mainSource =
		"using Tools;
	using Later;

	class Main {
		static function main():Int {
			var shape = Shape.Line(3);
			return \"ab\".shout().length + 4.twice() + shape.size() + shape.width();
		}
	}";

	static function initialSources():Map<String, String>
		return [
			"Tools.hx" => toolsSource,
			"Later.hx" => laterSource,
			"Shape.hx" => shapeSource,
			"ShapeTools.hx" => shapeToolsSource,
			"Main.hx" => mainSource
		];

	static function main():Void {
		var failures:Array<String> = [];
		edit(failures, "a later using gains the extension a call reached in an earlier one",
			files -> files.set("Later.hx",
			"class Later {
					public static function twice(x:Int):Int return x * 2;
					public static function shout(s:String):String return s + \"?!\";
				}"));
		edit(failures, "an extension changes its signature",
			files -> files.set("Later.hx", "class Later { public static function twice(x:Float):Int return 5; }"));
		edit(failures, "a type's @:using gains the extension a module's using gave",
			files -> files.set("ShapeTools.hx",
			"class ShapeTools {
					public static function width(shape:Shape):Int return 2;
					public static function size(shape:Shape):Int return 7;
				}"));
		edit(failures, "a type loses its @:using",
			files -> {
				files.set("Shape.hx", "enum Shape { Dot; Line(length:Int); }");
				files.set("Tools.hx",
					"class Tools {
						public static function shout(s:String):String return s + \"!\";
						public static function size(shape:Shape):Int return 1;
						public static function width(shape:Shape):Int return 9;
					}");
			});
		edit(failures, "a module's using goes", files -> {
			files.set("Main.hx", StringTools.replace(mainSource, "using Later;", ""));
			files.set("Tools.hx",
				"class Tools {
					public static function shout(s:String):String return s + \"!\";
					public static function size(shape:Shape):Int return 1;
					public static function twice(x:Int):Int return 0;
				}");
		});
		reject(failures, "the extension a call reached goes",
			files -> files.set("Later.hx", "class Later { public static function thrice(x:Int):Int return x * 3; }"));
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println("PASS: a warm build after the static extensions change equals a fresh one");
	}

	/** Builds the program, applies `change` in the same session and builds again; the warm module must be the fresh one's bytes. */
	static function edit(failures:Array<String>, label:String, change:Map<String, String>->Void):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			compiler.compile("Main");
			change(files);
			for (path => text in files)
				compiler.update(path, text);
			var warm = compiler.compile("Main").artifact.hashLink().hashLinkBytes().flatten(),
				fresh = newCompiler(files).compile("Main").artifact.hashLink().hashLinkBytes().flatten();
			if (warm.compare(fresh) != 0)
				throw 'the warm module differs from a fresh one (${warm.length} and ${fresh.length} bytes)';
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}

	/** An edit that breaks a call in a module it leaves alone: the warm build must report the error a fresh build reports. */
	static function reject(failures:Array<String>, label:String, change:Map<String, String>->Void):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			compiler.compile("Main");
			change(files);
			for (path => text in files)
				compiler.update(path, text);
			var warm = failure(() -> compiler.compile("Main")),
				fresh = failure(() -> newCompiler(files).compile("Main"));
			if (fresh == null)
				throw "a fresh build accepts the edit";
			if (warm != fresh)
				throw 'the warm build reports ${warm == null ? "no error" : '"$warm"'} where a fresh one reports "$fresh"';
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}

	static function failure(build:() -> Dynamic):Null<String> {
		try
			build()
		catch (error:compiler.core.Diagnostic.CompileError)
			return Std.string(error);
		return null;
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
