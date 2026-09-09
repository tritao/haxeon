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
			+ '\textern fn isNull(value: nullable<ptr<const<void>>>) -> i32 @symbol("native_fixture_is_null");\n'
			+
			'\textern fn sum16(a0: i32, a1: i32, a2: i32, a3: i32, a4: i32, a5: i32, a6: i32, a7: i32, a8: i32, a9: i32, a10: i32, a11: i32, a12: i32, a13: i32, a14: i32, a15: i32) -> i32 @symbol("native_fixture_sum16");\n'
			+ '\textern fn i64Value() -> i64 @symbol("native_fixture_i64_value");\n'
			+ '\textern fn i64Check(value: i64) -> i32 @symbol("native_fixture_i64_check");\n'
			+ '}\n');
		compiler.update("Main.hx",
			"import Fixture; function main():Int return Fixture.multiply(6.0, 7.0) == 42.0 && Fixture.isNull(haxe.io.Bytes.alloc(1)) == 0 && Fixture.isNull(null) == 42 && Fixture.sum16(1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 0, 0, 0, 0, 0) == 42 && Fixture.i64Check(Fixture.i64Value()) == 42 ? Fixture.add(Fixture.add(10, 11), 21) : 1;");
		compiler.compile("Main");
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
