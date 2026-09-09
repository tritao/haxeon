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
		expect(first.indexOf("extern fn sample_check_utf8(value: utf8, optional: nullable<utf8>)") >= 0,
			"explicit UTF-8 marker typedefs should import as string contracts");
		expect(first.indexOf("extern fn sample_create(") >= 0, "functions should import");
		expect(first.indexOf("type sample_handle = u32") >= 0, "fixed-width C types should use raw-HXI primitives");
		expect(first.indexOf("callback sample_binary_callback = fn(arg0: i32, arg1: i32) -> i32") >= 0,
			"function pointer typedefs should import as typed callbacks");
		expect(first.indexOf("callback sample_visit_callback = fn(arg0: ptr<const<sample_options>>, arg1: ptr<void>) -> void") >= 0,
			"function pointer imports should preserve structure and user-data pointers");
		expect(first.indexOf("extern fn sample_apply_nullable(callback: nullable<sample_binary_callback>)") >= 0,
			"Clang callback nullability should survive HXI import");
		expect(first.indexOf("const SAMPLE_FLAG = 8") >= 0, "constant expressions should use Clang's evaluated value");
		expect(first.indexOf("enum sample_result : c_int") >= 0 && first.indexOf("SAMPLE_RESULT_FAILED = -1") >= 0,
			"named C enums should import as nominal HXI enums");
		expect(first.indexOf("extern fn sample_check_result(value: sample_result) -> sample_result") >= 0,
			"enum function signatures should retain their nominal type");
		expect(first.indexOf("int_fast16_t") < 0, "system-header declarations should not leak into imported HXI");
		var parsed = HxiParser.parse("import_fixture.hxi", first);
		expect(parsed.target == "x86_64-linux-gnu", "generated HXI should satisfy the validated parser contract");
		var windows = CHeaderImporter.importHeader("tests/ffi/import_fixture.h", "i686-w64-windows-gnu", ["tests/ffi"]);
		expect(windows.indexOf('callback sample_stdcall_callback = fn(arg0: i32) -> i32 @callconv("stdcall")') >= 0
			&& windows.indexOf('extern fn sample_stdcall_function(value: i32) -> i32 @callconv("stdcall")') >= 0,
			"Clang calling conventions should survive callback and function import");
		HxiParser.parse("import_fixture-windows.hxi", windows);
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
