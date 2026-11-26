using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A warm build after an interface's variables change gives the bytes of a fresh build of the same sources. The class that
 * implements the interface lives in a module the edit leaves alone, but the accessors it is given for the interface's variables
 * (`InterfaceFieldAccessors`) follow the interface: one appears, goes or changes with the edit, as a fresh build has it.
 */
class InterfaceVariablesWarmEditMain {
	static final shapeSource = "interface Shape { var x:Int; var area(get, never):Int; }";

	static final squareSource =
		"class Square implements Shape {
		public var x:Int = 3;
		public var y:Int = 4;
		public var area(get, never):Int;
		public function new() {}
		function get_area():Int return x * x;
	}";

	static final mainSource =
		"class Main {
		static function main():Int {
			var shape:Shape = new Square();
			shape.x += 1;
			return shape.x + shape.area;
		}
	}";

	static function initialSources():Map<String, String>
		return ["Shape.hx" => shapeSource, "Square.hx" => squareSource, "Main.hx" => mainSource];

	static function main():Void {
		var failures:Array<String> = [];
		edit(failures, "an interface gains a variable its class has",
			files -> files.set("Shape.hx", "interface Shape { var x:Int; var y:Int; var area(get, never):Int; }"));
		edit(failures, "an interface's variable becomes read-only",
			files -> {
				files.set("Shape.hx", "interface Shape { var x(default, null):Int; var area(get, never):Int; }");
				files.set("Main.hx", StringTools.replace(mainSource, "shape.x += 1;", ""));
			});
		edit(failures, "an interface loses a variable",
			files -> {
				files.set("Shape.hx", "interface Shape { var area(get, never):Int; }");
				files.set("Main.hx",
					StringTools.replace(StringTools.replace(mainSource, "shape.x += 1;", ""), "shape.x + ",
					""));
			});
		reject(failures, "an interface's variable becomes a property its class lacks",
			files -> files.set("Shape.hx", "interface Shape { var x(get, never):Int; var area(get, never):Int; }"));
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println("PASS: a warm build after an interface's variables change equals a fresh one");
	}

	/** Builds the program, applies `change` in the same session and builds again; the warm module must be the fresh one's bytes. */
	static function edit(failures:Array<String>, label:String, change:Map<String, String>->Void):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			compiler.compile("Main");
			change(files);
			for (path => text in files)
				compiler.update(path, text);
			compiler.addSourceRoot("stdlib");
			var warm = compiler.compile("Main").artifact.hashLink().hashLinkBytes().flatten(),
				fresh = newCompiler(files).compile("Main").artifact.hashLink().hashLinkBytes().flatten();
			if (warm.compare(fresh) != 0)
				throw 'the warm module differs from a fresh one (${warm.length} and ${fresh.length} bytes)';
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}

	/** An edit that breaks a class it leaves alone: the warm build must report the error a fresh build reports. */
	static function reject(failures:Array<String>, label:String, change:Map<String, String>->Void):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			compiler.compile("Main");
			change(files);
			for (path => text in files)
				compiler.update(path, text);
			compiler.addSourceRoot("stdlib");
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
