import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/** Class members take precedence over same-named module functions in cold and incremental builds. */
class MemberModuleShadowMain {
	static function main():Void {
		var base = 'function value():Int return 100; '
			+ 'class Base { public var value:Int; public var callback:Int->Int; '
			+ 'public function new() { value=20; callback=function(x:Int):Int return x; } '
			+ 'public function get():Int return value+1; }';
		var consumer = 'function value():Int return 100; function get():Int return 100; function standalone():Int return 0; '
			+ 'function bonus():Int return 100; function field():Int return 100; '
			+ 'function callback(x:Int):Int return 100; '
			+ 'struct Point { public var field:Int; public function new(field:Int) this.field=field; public function read():Int return field; } '
			+ 'class Choice { static var bonus:Int=0; public static function score():Int return bonus; } '
			+ 'class Main extends Base { public function new() super(); '
			+ 'function local():Int { var value=2; return value; } '
			+ 'function methodReference():Int { var f:Void->Int=get; return f(); } '
			+ 'function read():Int return value+get()+callback(1)+standalone()+Choice.score()+new Point(0).read()+local()-2+methodReference()-get(); '
			+ 'static function main():Int return new Main().read(); }';
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.update("Base.hx", base);
		compiler.update("Main.hx", consumer);
		check(compiler, 42);
		compiler.update("Base.hx", StringTools.replace(base, "value=20", "value=19"));
		check(compiler, 40);
		compiler.update("Base.hx", StringTools.replace(base, "value+1", "value+2"));
		check(compiler, 43);
		compiler.update("Base.hx", base);
		compiler.update("Main.hx", StringTools.replace(consumer, "return 100", "return 101"));
		check(compiler, 42);
		var rebound = new Compiler(null, CompilerIntrinsics.configuration());
		var emptyBase = 'class Base { public function new() {} }';
		var memberBase = 'class Base { public function new() {} public function value():Int return 41; }';
		rebound.update("Base.hx", emptyBase);
		rebound.update("Main.hx", 'function value():Int return 42; class Main extends Base { public function new() super(); '
			+ 'function read():Int return value(); static function main():Int return new Main().read(); }');
		check(rebound, 42);
		rebound.update("Base.hx", memberBase);
		check(rebound, 41);
		rebound.update("Base.hx", emptyBase);
		check(rebound, 42);
		Sys.println("PASS: inherited fields and methods shadow module functions through incremental edits");
	}

	static function check(compiler:Compiler, expected:Int):Void {
		var actual = GeneratedProgramRunner.exitCode(compiler.compile("Main"));
		if (actual != expected) throw 'expected $expected, got $actual';
	}
}
