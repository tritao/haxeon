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
			+ '\tstruct fixture_item @layout(8, 8) { name: utf8 @offset(0); }\n'
			+
			'\tstruct fixture_options @layout(48, 8) { items: ptr<const<fixture_item>> @offset(0) @borrowed @length_field("item_count"); item_count: u32 @offset(8); paths: ptr<utf8> @offset(16) @borrowed @length_field("path_count"); path_count: u32 @offset(24); data: ptr<const<u8>> @offset(32) @borrowed @length_field("size"); size: u32 @offset(40); }\n'
			+
			'\tstruct fixture_container @layout(64, 8) { value: fixture_options @offset(0); options: ptr<const<fixture_options>> @offset(48) @borrowed @length_field("count"); count: u32 @offset(56); }\n'
			+ '\textern fn i64Value() -> i64 @symbol("native_fixture_i64_value");\n'
			+
			'\textern fn check(value: ptr<const<fixture_container>>, extracted: ptr<const<fixture_options>>) -> i32 @symbol("native_fixture_check_retained_container");\n'
			+ '}\n');
		compiler.update("Main.hx",
			'import FixtureRetained; function makeOptions():fixture_options { var item = new fixture_item(); item.set_name("retained-entry"); var options = new fixture_options(); options.set_items([item]); options.set_paths(["alpha", "beta"]); options.set_data_bytes(haxe.io.Bytes.ofString("buffer!")); return options; } function makeContainer():fixture_container { var options = makeOptions(); var container = new fixture_container(); container.set_value(options); container.set_options([options]); return container; } function main():Int { var container = makeContainer(); var index = 0; while (index < 30000) { var garbage = haxe.io.Bytes.alloc(256); var transient = [index, index + 1, index + 2, index + 3]; if (garbage == null || transient[0] != index) return 1; index = index + 1; } return FixtureRetained.check(container, container.get_value()); }');
		var result = compiler.compile("Main");
		File.saveBytes(output, HlWriter.encode(result.module));
	}
}
