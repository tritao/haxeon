import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import compiler.Compiler.CompileResult;
import sys.FileSystem;
import sys.io.File;

/**
 * A live edit lowers again only the functions it regenerated. A function in an untouched file that inlined the same
 * library code as the edited function keeps its lowering: re-lowering every function that touched a file a
 * regenerated function touched redid most of the editor on each edit, for identical bytes.
 */
class LiveLoweringReuseMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/live-lowering-reuse-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var lib = root + "/Lib.hx",
			edited = root + "/Edited.hx",
			other = root + "/Other.hx",
			main = root + "/Main.hx",
			output = root + "/main.hl";
		File.saveContent(lib, "class Lib { public static function twice(value:Int):Int { return value * 2; } }");
		File.saveContent(edited, "class Edited { public static function value():Int { return Lib.twice(3); } }");
		File.saveContent(other, "class Other { public static function value():Int { return Lib.twice(5); } }");
		File.saveContent(main, "class Main { public static function main():Int { return Edited.value() + Other.value(); } }");
		var args = [
			"--target=hl",
			"--entry=Main",
			"--root=" + root,
			"--live",
			"--output=" + output,
			main,
			lib,
			edited,
			other
		], session = new CompilerSession();
		function compile()
			return CompilerDriver.compile(CompilerArguments.parse(args), _ -> {}, session);
		var initial = compile();
		File.saveContent(edited, "class Edited { public static function value():Int { return Lib.twice(4); } }");
		var changed = compile();
		expect(functionByName(initial, "Edited.value") != functionByName(changed, "Edited.value"), "the edited function must be lowered again");
		expect(functionByName(initial, "Other.value") == functionByName(changed, "Other.value"),
			"a function in an untouched file must keep its lowering, even if it inlined the same code as the edited function");
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: a live edit lowers again only the functions it regenerated");
	}

	static function functionByName(result:CompileResult, name:String):compiler.hl.HlFunction {
		var index = result.functionIndices.get(name);
		for (fn in result.module.functions)
			if (fn.functionIndex == index)
				return fn;
		throw 'Missing lowered function "$name"';
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
