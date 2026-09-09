import compiler.ffi.CHeaderImporter;
import compiler.ffi.HxiParser;

class CHeaderImporterMain {
	static function main():Void {
		var first = CHeaderImporter.importHeader("tests/ffi/import_fixture.h", "x86_64-linux-gnu", ["tests/ffi"]),
			second = CHeaderImporter.importHeader("tests/ffi/import_fixture.h", "x86_64-linux-gnu", ["tests/ffi"]);
		expect(first == second, "C header import must be deterministic");
		expect(first.indexOf("struct sample_options @layout(32, 8)") >= 0, "record layout should come from Clang");
		expect(first.indexOf("title: ptr<const<c_char>> @offset(8)") >= 0, "pointer field offset should be preserved");
		expect(first.indexOf("extern fn sample_error() -> ptr<const<c_char>>") >= 0, "pointer results should import");
		expect(first.indexOf("extern fn sample_create(") >= 0, "functions should import");
		expect(first.indexOf("type sample_handle = u32") >= 0, "fixed-width C types should use raw-HXI primitives");
		expect(first.indexOf("const SAMPLE_FLAG = 8") >= 0, "constant expressions should use Clang's evaluated value");
		expect(first.indexOf("int_fast16_t") < 0, "system-header declarations should not leak into imported HXI");
		var parsed = HxiParser.parse("import_fixture.hxi", first);
		expect(parsed.target == "x86_64-linux-gnu", "generated HXI should satisfy the validated parser contract");
		var diagnostic = "";
		try
			CHeaderImporter.importHeader("tests/ffi/unsupported_fixture.h", "x86_64-linux-gnu", ["tests/ffi"])
		catch (error:Dynamic)
			diagnostic = Std.string(error);
		expect(diagnostic.indexOf("unsupported_fixture.h:1:") >= 0 && diagnostic.indexOf("unsupported variadic function") >= 0,
			"unsupported declarations should report their source location");
		Sys.println("PASS: Clang C headers import into deterministic raw HXI");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
