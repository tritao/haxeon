import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Validates compile-time method discovery diagnostics. */
class UtestDiscoveryMain {
	static function main():Void {
		expectInvalid('class InvalidTest extends utest.Test { public static function testBad():Void {} } function main():Int return 0;',
			'Discovered method "InvalidTest.testBad" must be a parameterless instance method');
		expectInvalid('class InvalidTest extends utest.Test { public function testBad(value:Int):Void {} } function main():Int return 0;',
			'Discovered method "InvalidTest.testBad" must be a parameterless instance method');
		expectInvalid('class InvalidTest extends utest.Test { public function testBad():Int return 42; } function main():Int return 0;',
			'Discovered method "InvalidTest.testBad" must return Void');
		expectInvalid('@:discoverMethods(1) class Base {} class Child extends Base {} function main():Int return 0;',
			'@:discoverMethods prefixes must be string literals');
		Sys.println("PASS: method discovery rejects invalid metadata and test signatures");
	}

	static function expectInvalid(source:String, expected:String):Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.update("utest/Test.hx", File.getContent("stdlib/utest/Test.hx"));
		compiler.update("Main.hx", source);
		try {
			compiler.compile("Main");
			throw "invalid discovery source compiled";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1024" || error.diagnostic.message != expected)
				throw error;
		}
	}
}
