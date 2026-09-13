import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Compiles a minimal HXI program whose generated struct is retained in an object field. */
class HxiRetainedMain {
	static function main():Void {
		var output = Sys.args()[0],
			library = Sys.args()[1],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface("retained.hxi",
			'interface FixtureRetained @target("x86_64-linux-gnu") @library("$library") {\n'
			+ '\tstruct fixture_options @layout(32, 8) { count: i32 @offset(0); scale: f64 @offset(8); token: i64 @offset(16); delta: i16 @offset(24); }\n'
			+ '\textern fn i64Value() -> i64 @symbol("native_fixture_i64_value");\n'
			+ '\textern fn check(value: ptr<const<fixture_options>>) -> i32 @symbol("native_fixture_check_options");\n'
			+ '}\n');
		compiler.update("Main.hx",
			'import FixtureRetained; class Holder { public var options:fixture_options; public function new() { options = new fixture_options(); } } function main():Int { var holder = new Holder(); holder.options.set_count(40); holder.options.set_scale(1.5); holder.options.set_token(FixtureRetained.i64Value()); holder.options.set_delta(2); var index = 0; while (index < 10000) { var garbage = haxe.io.Bytes.alloc(32); var transient = [index, index + 1, index + 2, index + 3]; if (garbage == null || transient[0] != index) return 1; index = index + 1; } return FixtureRetained.check(holder.options); }');
		var result = compiler.compile("Main");
		File.saveBytes(output, HlWriter.encode(result.module));
	}
}
