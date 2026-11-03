import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/** Cached map operations must retain the typer's selected physical owner. */
class ScalarMapIncrementalMain {
	static function main():Void {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.addSourceRoot("stdlib");
		compiler.update("Other.hx", "class Other { public static function code():Int return 42; }");
		compiler.update("Main.hx", 'import haxeon.collections.HashMap; function main():Int { '
			+ 'var map:Map<Float,Int> = new Map(); map.set(Math.NaN, 7); map.set(Math.NaN, 8); '
			+ 'var native:Map<Int,Int> = new Map(); native.set(1, 9); '
			+ 'var generic:HashMap<Int,Int> = new HashMap(); generic.set(1, 10); '
			+ 'return map.size()==1 && map.get(Math.NaN)==8 && native.get(1)==9 && generic.get(1)==10 ? Other.code() : 1; }');
		if (GeneratedProgramRunner.exitCode(compiler.compile("Main")) != 42) throw "initial map specialization failed";
		compiler.update("Other.hx", "class Other { public static function code():Int return 41; }");
		if (GeneratedProgramRunner.exitCode(compiler.compile("Main")) != 41) throw "incremental map owner selection failed";
		Sys.println("PASS: map owners remain consistent across incremental compilation");
	}
}
