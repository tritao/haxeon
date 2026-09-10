import compiler.ffi.CHeaderImporter;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiProjection;

class CHeaderImporterMain {
	static function main():Void {
		var first = CHeaderImporter.importHeader("tests/ffi/import_fixture.h", "x86_64-linux-gnu", ["tests/ffi"]),
			second = CHeaderImporter.importHeader("tests/ffi/import_fixture.h", "x86_64-linux-gnu", ["tests/ffi"]);
		expect(first == second, "C header import must be deterministic");
		expect(first.indexOf("struct sample_options @layout(32, 8)") >= 0, "record layout should come from Clang");
		expect(first.indexOf("title: nullable<utf8> @offset(8)") >= 0, "annotated UTF-8 field offsets should be preserved");
		expect(first.indexOf('data: ptr<const<void>> @offset(0) @borrowed @length_field("data_size")') >= 0,
			"borrowed buffer field annotations should retain their length contract");
		expect(first.indexOf("extern fn sample_error() -> utf8 @borrowed") >= 0,
			"annotated borrowed UTF-8 results should import with their ownership contract");
		expect(first.indexOf("extern fn sample_check_utf8(value: utf8, optional: nullable<utf8>)") >= 0,
			"explicit UTF-8 marker typedefs should import as string contracts");
		expect(first.indexOf("extern fn sample_check_annotated_utf8(value: utf8, optional: nullable<utf8>)") >= 0,
			"parameter annotations should import as UTF-8 string contracts");
		expect(first.indexOf("extern fn sample_create(") >= 0, "functions should import");
		expect(first.indexOf("output: ptr<sample_handle> @out") >= 0, "output annotations should import as parameter directions");
		expect(first.indexOf('data: nullable<ptr<u8>> @out_buffer("size"), size: ptr<u32> @inout') >= 0,
			"paired output-buffer annotations should retain their size parameter");
		expect(first.indexOf('options: ptr<const<sample_options>> @in_array("count"), count: u32') >= 0
			&& first.indexOf('paths: ptr<utf8> @in_array("count"), count: u32') >= 0,
			"paired structure and UTF-8 input arrays should retain their count parameter");
		expect(first.indexOf("type sample_handle = u32") >= 0, "fixed-width C types should use raw-HXI primitives");
		expect(first.indexOf("callback sample_binary_callback = fn(arg0: i32, arg1: i32) -> i32") >= 0,
			"function pointer typedefs should import as typed callbacks");
		expect(first.indexOf("callback sample_visit_callback = fn(arg0: ptr<const<sample_options>>, arg1: ptr<void>) -> void") >= 0,
			"function pointer imports should preserve structure and user-data pointers");
		expect(first.indexOf("extern fn sample_apply_nullable(callback: nullable<sample_binary_callback>)") >= 0,
			"Clang callback nullability should survive HXI import");
		expect(first.indexOf("paths: ptr<const<ptr<const<c_char>>>>, out_path: ptr<ptr<const<c_char>>>") >= 0,
			"pointer-to-pointer types should preserve pointee qualifiers");
		expect(first.indexOf("const SAMPLE_FLAG = 8") >= 0, "constant expressions should use Clang's evaluated value");
		expect(first.indexOf("const SAMPLE_U32_MAX = -1") >= 0, "unsigned 32-bit constants should preserve their bit pattern as Haxe Int values");
		expect(first.indexOf("enum sample_result : c_int") >= 0 && first.indexOf("SAMPLE_RESULT_FAILED = -1") >= 0,
			"named C enums should import as nominal HXI enums");
		expect(first.indexOf("extern fn sample_check_result(value: sample_result) -> sample_result") >= 0,
			"enum function signatures should retain their nominal type");
		expect(first.indexOf("int_fast16_t") < 0, "system-header declarations should not leak into imported HXI");
		var parsed = HxiParser.parse("import_fixture.hxi", first);
		expect(parsed.target == "x86_64-linux-gnu", "generated HXI should satisfy the validated parser contract");
		var named = CHeaderImporter.importHeader("tests/ffi/import_fixture.h", "x86_64-linux-gnu", ["tests/ffi"], "clang", "sample", "Sample");
		var projected = HxiProjection.source(HxiParser.parse("import_fixture.hxi", named));
		expect(projected.indexOf("static inline function size():Int return 32") >= 0,
			"projected structures should expose their generated ABI size");
		expect(projected.indexOf("function set_title(value:Null<String>)") >= 0 && projected.indexOf("structSetUtf8") >= 0,
			"UTF-8 structure fields should project managed accessors");
		expect(named.indexOf('interface Sample @target("x86_64-linux-gnu") @library("sample")') >= 0,
			"callers should be able to select a stable projected interface name");
		var windows = CHeaderImporter.importHeader("tests/ffi/import_fixture.h", "i686-w64-windows-gnu", ["tests/ffi"]);
		expect(windows.indexOf('callback sample_stdcall_callback = fn(arg0: i32) -> i32 @callconv("stdcall")') >= 0
			&& windows.indexOf('extern fn sample_stdcall_function(value: i32) -> i32 @callconv("stdcall")') >= 0,
			"Clang calling conventions should survive callback and function import");
		HxiParser.parse("import_fixture-windows.hxi", windows);
		var orderAb = CHeaderImporter.importHeader("tests/ffi/import_order_ab.h", "x86_64-linux-gnu", ["tests/ffi"], "clang", "sample", "Order"),
			orderBa = CHeaderImporter.importHeader("tests/ffi/import_order_ba.h", "x86_64-linux-gnu", ["tests/ffi"], "clang", "sample", "Order");
		var bodyAb = orderAb.substring(orderAb.indexOf("interface ")),
			bodyBa = orderBa.substring(orderBa.indexOf("interface "));
		expect(bodyAb == bodyBa && bodyAb.indexOf("extern fn import_order_a") >= 0 && bodyAb.indexOf("extern fn import_order_b") >= 0,
			"included declarations should be complete and deterministic regardless of include order");
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
