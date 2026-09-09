import compiler.Compiler;
import compiler.hl.HlWriter;
import sys.io.File;

class HxiCallMain {
	static function main():Void {
		var output = Sys.args()[0],
			library = Sys.args()[1],
			compiler = new Compiler();
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface("fixture.hxi",
			'interface Fixture @target("x86_64-linux-gnu") @library("$library") {\n'
			+ '\textern fn add(left: i32, right: i32) -> i32 @symbol("native_fixture_add");\n'
			+ '\textern fn multiply(left: f64, right: f64) -> f64 @symbol("native_fixture_multiply");\n'
			+ '\textern fn isNull(value: ptr<const<void>>) -> i32 @symbol("native_fixture_is_null");\n'
			+ '}\n');
		compiler.update("Main.hx",
			"import Fixture; function main():Int return Fixture.multiply(6.0, 7.0) == 42.0 && Fixture.isNull(haxe.io.Bytes.alloc(1)) == 0 ? Fixture.add(Fixture.add(10, 11), 21) : 1;");
		compiler.compile("Main");
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
