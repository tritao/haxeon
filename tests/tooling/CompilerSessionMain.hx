import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import compiler.Compiler.CompileResult;
import sys.FileSystem;
import sys.io.File;

class CompilerSessionMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/compiler-session-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var main = root + "/Main.hx", value = root + "/Value.hx", output = root + "/main.hl", fresh = root + "/fresh.hl";
		File.saveContent(main, "class Main { public static function main():Int { return Value.get(); } }");
		File.saveContent(value, "class Value { public static function get():Int { return 7; } }");
		var args = ["--target=hl", "--entry=Main", "--root=" + root, main, value], session = new CompilerSession();
		function compile() return CompilerDriver.compile(CompilerArguments.parse(args.concat(["--output=" + output])), _ -> {}, session);
		function compareFresh(expected:Int):Void {
			CompilerDriver.compile(CompilerArguments.parse(args.concat(["--output=" + fresh])), _ -> {});
			var variable = Sys.systemName() == "Windows" ? "PATH" : Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH",
				separator = Sys.systemName() == "Windows" ? ";" : ":", previousPath = Sys.getEnv(variable),
				runtime = FileSystem.fullPath(".tools/hashlink/hl" + (Sys.systemName() == "Windows" ? ".exe" : ""));
			Sys.putEnv(variable, FileSystem.fullPath("out") + separator + FileSystem.fullPath(".tools/hashlink")
				+ (previousPath == null ? "" : separator + previousPath));
			expect(Sys.command(runtime, [output]) == expected, "incremental bytecode must execute the edited program");
			expect(Sys.command(runtime, [fresh]) == expected, "fresh bytecode must execute the same program");
			Sys.putEnv(variable, previousPath == null ? "" : previousPath);
			expect(File.getContent(output + ".functions").indexOf("\tMain.main\n") >= 0,
				"incremental bytecode must publish its stable function map");
			expect(File.getContent(fresh + ".functions").indexOf("\tMain.main\n") >= 0,
				"fresh bytecode must publish its function map");
		}
		var initial = compile();
		var unchanged = compile();
		expect(unchanged.retyped.length == 0, "unchanged compilation reuses semantic state");
		File.saveContent(value, "class Value { public static function get():Int { return 9; } }");
		var edited = compile();
		expect(edited.retyped.length > 0, "a source edit must retype affected modules");
		expect(functionByName(initial, "Main.main") == functionByName(edited, "Main.main"),
			"backend assembly must reuse functions from unchanged source files");
		compareFresh(9);
		var lazy = root + "/Lazy.hx";
		File.saveContent(lazy, "class Lazy { public static function value():Int { return 23; } }");
		File.saveContent(main, "class Main { public static function main():Int { return Lazy.value(); } }");
		compile();
		var beforeLazy = File.getBytes(output);
		File.saveContent(lazy, "class Lazy { public static function value():Int { return 29; } }");
		compile();
		expect(beforeLazy.compare(File.getBytes(output)) != 0, "lazily loaded imports must be refreshed by module identity");
		compareFresh(29);
		File.saveContent(main, "class Main { public static function main():Int { return Value.get(); } }");
		File.saveContent(value, "class Value { public static function extra():Int { return 3; } public static function get():Int { return extra(); } }");
		compile();
		compareFresh(3);
		File.saveContent(value, "class Value { public static function get():Int { return missing; } }");
		var failed = false;
		try compile() catch (_:Dynamic) { failed = true; session.reset(); }
		expect(failed, "compile errors must be reported");
		File.saveContent(value, "class Value { public static function get():Int { return 11; } }");
		compile();
		compareFresh(11);
		FileSystem.deleteFile(value);
		args.remove(value);
		failed = false;
		try compile() catch (_:Dynamic) { failed = true; session.reset(); }
		expect(failed, "removed sources must not survive in the session");
		File.saveContent(main, "class Main { public static function main():Int { #if feature return 13; #else return 0; #end } }");
		args.push("--define=feature");
		compile();
		compareFresh(13);
		var hxi = root + "/fixture.hxi";
		File.saveContent(hxi, 'interface fixture @target("portable-abi64") @library("fixture") { const VALUE = 17; }');
		args.push("--ffi-interface=" + hxi);
		File.saveContent(main, "import fixture; import fixture.FixtureConstants; class Main { public static function main():Int { return FixtureConstants.VALUE; } }");
		compile();
		var beforeFfi = File.getBytes(output);
		File.saveContent(hxi, 'interface fixture @target("portable-abi64") @library("fixture") { const VALUE = 19; }');
		compile();
		expect(beforeFfi.compare(File.getBytes(output)) != 0, "FFI edits must replace projected modules");
		compareFresh(19);
		var generic = root + "/Generic.hx";
		File.saveContent(generic, "class Generic { static function identity<T>(v:T):Int { return 7; } public static function get():Int { var f = () -> identity(7); return f(); } }");
		args.push(generic);
		File.saveContent(main, "class Main { public static function main():Int { return Generic.get(); } }");
		compile();
		File.saveContent(main, "class Main { public static function main():Int { return Generic.get() + 1; } }");
		compile();
		compareFresh(8);
		File.saveContent(generic, File.getContent(generic).split("return 7;").join("return 11;"));
		compile();
		compareFresh(12);
		for (path in FileSystem.readDirectory(root)) FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: compiler session reuse, edits, failure recovery, source removal, FFI/lazy imports, and generic invalidation");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function functionByName(result:CompileResult, name:String):compiler.hl.HlFunction {
		var index = result.functionIndices.get(name);
		for (fn in result.module.functions)
			if (fn.functionIndex == index)
				return fn;
		throw 'Missing lowered function "$name"';
	}
}
