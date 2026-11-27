using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Compiles a minimal HXI program whose generated struct is retained in an object field. */
class HxiRetainedMain {
	static function main():Void {
		var output = Sys.args()[0],
			library = Sys.args()[1],
			compiler = new Compiler();
		var target = Sys.getEnv("HAXEON_GC_BOUNDARY_TARGET");
		if (target == null)
			target = "x86_64-linux-gnu";
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface("retained.hxi",
			'interface FixtureRetained @target("$target") @library("$library") {\n'
			+ '\tstruct fixture_item { name: utf8; }\n'
			+ '\tstruct fixture_options { items: ptr<const<fixture_item>> @borrowed @length_field("item_count"); item_count: u32; paths: ptr<utf8> @borrowed @length_field("path_count"); path_count: u32; data: ptr<const<u8>> @borrowed @length_field("size"); size: u32; }\n'
			+ '\tstruct fixture_container { value: fixture_options; options: ptr<const<fixture_options>> @borrowed @length_field("count"); count: u32; }\n'
			+ '\textern fn i64Value() -> i64 @symbol("native_fixture_i64_value");\n'
			+ '\textern fn check(value: ptr<const<fixture_container>>, extracted: ptr<const<fixture_options>>) -> i32 @symbol("native_fixture_check_retained_container");\n'
			+ '}\n');
		compiler.update("Main.hx",
			'import FixtureRetained; function makeOptions():fixture_options { var item = new fixture_item(); item.set_name("retained-entry"); var options = new fixture_options(); options.set_items([item]); options.set_paths(["alpha", "beta"]); options.set_data_bytes(haxe.io.Bytes.ofString("buffer!")); return options; } function makeContainer():fixture_container { var options = makeOptions(); var container = new fixture_container(); container.set_value(options); container.set_options([options]); return container; } function main():Int { var container = makeContainer(); var index = 0; while (index < 30000) { var garbage = haxe.io.Bytes.alloc(256); var transient = [index, index + 1, index + 2, index + 3]; if (garbage == null || transient[0] != index) return 1; index = index + 1; } return FixtureRetained.check(container, container.get_value()); }');
		if (Sys.getEnv("HAXEON_GC_BOUNDARY_STRESS") == "1") {
			var source = compiler.modules.get("Main").source.text;
			if (source.indexOf("function main():Int { var container = makeContainer();") < 0
				|| source.indexOf("return FixtureRetained.check(container, container.get_value());") < 0)
				throw "borrowed HXI GC stress source hooks are missing";
			source = StringTools.replace(source, "function main():Int { var container = makeContainer();",
				"function main():Int { hl.Gc.enable(false); var ballast = [for (i in 0...2000000) \"borrowed-ballast\"]; if (hl.Gc.step(0.001) || !hl.Gc.incrementalPending()) return 91; var container = makeContainer();");
			source = StringTools.replace(source, "return FixtureRetained.check(container, container.get_value());",
				"var completed = false; for (slice in 0...10000) { if (hl.Gc.step(1000.0)) { completed = true; break; } } if (!completed || ballast[1999999] != \"borrowed-ballast\") return 92; var result = FixtureRetained.check(container, container.get_value()); hl.Gc.enable(true); return result;");
			compiler.update("Main.hx", source);
		}
		var result = compiler.compile("Main");
		File.saveBytes(output, result.artifact.hashLink().hashLinkBytes().flatten());
	}
}
