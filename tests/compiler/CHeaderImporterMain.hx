import compiler.ffi.CHeaderImporter;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiWriter;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiProjection;
import sys.FileSystem;

@:access(compiler.ffi.CHeaderImporter)
class CHeaderImporterMain {
	static function main():Void {
		var windowsLayout = CHeaderImporter.parseLayouts("*** Dumping AST Record Layout\r\n"
			+ "         0 | struct sample_options\r\n"
			+ "         0 |   uint32_t struct_size\r\n"
			+ "         8 |   const char * title\r\n"
			+ "        16 |   uint64_t reserved[2]\r\n"
			+ "           | [sizeof=32, dsize=32, align=8, nvsize=32, nvalign=8]\r\n")
			.get("sample_options");
		expect(windowsLayout != null && windowsLayout.size == 32 && windowsLayout.align == 8 && windowsLayout.offsets.get("title") == 8,
			"record layout parser should accept Clang's Windows CRLF output");
		var labeledLayout = CHeaderImporter.parseLayouts("*** Dumping AST Record Layout\n" + "         0 | class sample_class\n"
			+ "         0 |   uint32_t value\n" + "           | Size:32\n" + "           | Alignment:8\n")
			.get("sample_class");
		expect(labeledLayout != null && labeledLayout.size == 32 && labeledLayout.align == 8 && labeledLayout.offsets.get("value") == 0,
			"record layout parser should accept labeled Clang size and alignment trailers");
		var firstModel = CHeaderImporter.importHeader("tests/ffi/import_fixture.h", "x86_64-linux-gnu", ["tests/ffi"]),
			first = HxiWriter.write(firstModel, generatedHeader("tests/ffi/import_fixture.h", "x86_64-linux-gnu")),
			second = importHeaderText("tests/ffi/import_fixture.h", "x86_64-linux-gnu", ["tests/ffi"]);
		expect(Std.isOfType(firstModel, HxiInterface)
			&& firstModel.name == "import_fixture_h", "C header importer should return a typed HXI interface");
		expect(first == second, "C header import must be deterministic");
		if (first.indexOf("struct sample_options @layout(32, 8)") < 0) {
			var layoutText = CHeaderImporter.lastLayoutText,
				marker = layoutText == null ? -1 : layoutText.indexOf("sample_options"),
				preview = layoutText == null ? "<null>" : marker < 0 ? layoutText.substring(0,
					Std.int(Math.min(512,
						layoutText.length))) : layoutText.substring(Std.int(Math.max(0, marker - 128)), Std.int(Math.min(layoutText.length, marker + 512)));
			throw 'record layout should come from Clang (captured ${layoutText == null ? -1 : layoutText.length} bytes, marker $marker): $preview';
		}
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
		expect(first.indexOf('values: nullable<ptr<utf8>> @out_array("count"), count: ptr<u32> @inout') >= 0,
			"counted UTF-8 pointer-array outputs should import with their count contract");
		expect(first.indexOf('options: ptr<const<sample_options>> @in_array("count"), count: u32') >= 0
			&& first.indexOf('paths: ptr<utf8> @in_array("count"), count: u32') >= 0,
			"paired structure and UTF-8 input arrays should retain their count parameter");
		expect(first.indexOf("handle sample_handle : u32") >= 0, "annotated fixed-width handles should use nominal HXI handles");
		expect(first.indexOf('handle sample_owned_handle : u32 @destroy("sample_owned_handle_destroy")') >= 0,
			"annotated handle destroy symbols should survive C-to-HXI import");
		expect(first.indexOf('extern fn sample_create_owned() -> sample_owned_handle @owned') >= 0
			&& first.indexOf('output: ptr<sample_owned_handle> @out @owned') >= 0,
			"C ownership-transfer annotations should mark returned and output value handles explicitly");
		expect(first.indexOf("handle sample_resource : u32") >= 0 && first.indexOf("struct sample_resource") < 0,
			"annotated one-field handle records should use nominal HXI handles");
		expect(first.indexOf("callback sample_binary_callback = fn(arg0: i32, arg1: i32) -> i32") >= 0,
			"function pointer typedefs should import as typed callbacks");
		expect(first.indexOf("callback sample_visit_callback = fn(arg0: ptr<const<sample_options>>, arg1: ptr<void>) -> void") >= 0,
			"function pointer imports should preserve structure and user-data pointers");
		expect(first.indexOf("extern fn sample_apply_nullable(callback: nullable<sample_binary_callback>)") >= 0,
			"Clang callback nullability should survive HXI import");
		expect(first.indexOf("extern fn sample_set_retained(callback: sample_binary_callback @retained)") >= 0,
			"retained callback annotations should survive C header import");
		expect(first.indexOf("paths: ptr<const<ptr<const<c_char>>>>, out_path: ptr<ptr<const<c_char>>>") >= 0,
			"pointer-to-pointer types should preserve pointee qualifiers");
		expect(first.indexOf("const SAMPLE_FLAG = 8") >= 0, "constant expressions should use Clang's evaluated value");
		expect(first.indexOf("const SAMPLE_U32_MAX = -1") >= 0, "unsigned 32-bit constants should preserve their bit pattern as Haxe Int values");
		expect(first.indexOf("enum sample_result : c_int") >= 0 && first.indexOf("SAMPLE_RESULT_FAILED = -1") >= 0,
			"named C enums should import as nominal HXI enums");
		expect(first.indexOf("extern fn sample_check_result(value: sample_result) -> sample_result") >= 0,
			"enum function signatures should retain their nominal type");
		expect(first.indexOf("enum sample_mode : u32") >= 0
			&& first.indexOf("SAMPLE_MODE_ALTERNATE = 1") >= 0
			&& first.indexOf("type sample_mode = u32") < 0,
			"annotated fixed-width enum aliases should import as nominal HXI enums");
		expect(first.indexOf("flags sample_flags : u32") >= 0
			&& first.indexOf("SAMPLE_FLAGS_READ_WRITE = 3") >= 0
			&& first.indexOf("flags sample_wide_flags : u64") >= 0
			&& first.indexOf("SAMPLE_WIDE_FLAGS_HIGH = -9223372036854775808") >= 0,
			"annotated fixed-width bitmask aliases should retain flags semantics and 64-bit values");
		expect(first.indexOf("extern fn sample_check_mode(value: sample_mode) -> sample_mode") >= 0,
			"annotated enum aliases should retain their nominal type in function signatures");
		expect(first.indexOf("extern fn sample_check_flags(value: sample_flags) -> sample_flags") >= 0
			&& first.indexOf("extern fn sample_check_wide_flags(value: sample_wide_flags) -> sample_wide_flags") >= 0,
			"annotated flags aliases should retain their nominal type in function signatures");
		expect(first.indexOf("int_fast16_t") < 0, "system-header declarations should not leak into imported HXI");
		var parsed = HxiParser.parse("import_fixture.hxi", first);
		expect(parsed.target == "x86_64-linux-gnu", "generated HXI should satisfy the validated parser contract");
		var named = importHeaderText("tests/ffi/import_fixture.h", "x86_64-linux-gnu", ["tests/ffi"], "clang", "sample", "Sample");
		var projected = HxiProjection.source(HxiParser.parse("import_fixture.hxi", named));
		expect(projected.indexOf("class Ownedsample_owned_handle") >= 0
			&& projected.indexOf("Sample.sample_owned_handle_destroy(__value)") >= 0,
			"C handle lifecycle annotations should produce a managed owned value handle");
		expect(projected.indexOf("static inline function size():Int return 32") >= 0, "projected structures should expose their generated ABI size");
		expect(projected.indexOf("function set_title(value:Null<String>)") >= 0 && projected.indexOf("structSetUtf8") >= 0,
			"UTF-8 structure fields should project managed accessors");
		expect(projected.indexOf("enum abstract SampleFlags(Int)") >= 0
			&& projected.indexOf("abstract SampleWideFlags(haxe.Int64)") >= 0
			&& projected.indexOf("function contains(flag:SampleWideFlags):Bool") >= 0,
			"C header flags should project to nominal Haxe bitmasks at both integer widths");
		expect(named.indexOf('interface Sample @target("x86_64-linux-gnu") @library("sample")') >= 0,
			"callers should be able to select a stable projected interface name");
		var dependent = importHeaderText("tests/ffi/import_fixture.h", "x86_64-linux-gnu", ["tests/ffi"], "clang", "sample", "Dependent", ["Sample"]);
		expect(dependent.indexOf('@depends("Sample")') >= 0, "header importer should preserve HXI dependency metadata");
		var dependencyHeader = FileSystem.fullPath("tests/ffi/import_fixture.h"),
			filtered = importHeaderText("tests/ffi/dependency_wrapper.h", "x86_64-linux-gnu", ["tests/ffi"], "clang", "sample", "Filtered", ["Sample"], null,
				[dependencyHeader]);
		expect(filtered.indexOf("handle sample_handle") < 0 && filtered.indexOf("struct sample_options") < 0,
			"excluded dependency headers should not be projected into the dependent HXI");
		expect(filtered.indexOf("struct dependency_extra") >= 0 && filtered.indexOf("extern fn dependency_use(value: sample_handle") >= 0,
			"dependent headers should retain their own declarations and dependency references");
		var windows = importHeaderText("tests/ffi/import_fixture.h", "i686-w64-windows-gnu", ["tests/ffi"]);
		expect(windows.indexOf('callback sample_stdcall_callback = fn(arg0: i32) -> i32 @callconv("stdcall")') >= 0
			&& windows.indexOf('extern fn sample_stdcall_function(value: i32) -> i32 @callconv("stdcall")') >= 0,
			"Clang calling conventions should survive callback and function import");
		HxiParser.parse("import_fixture-windows.hxi", windows);
		var orderAb = importHeaderText("tests/ffi/import_order_ab.h", "x86_64-linux-gnu", ["tests/ffi"], "clang", "sample", "Order"),
			orderBa = importHeaderText("tests/ffi/import_order_ba.h", "x86_64-linux-gnu", ["tests/ffi"], "clang", "sample", "Order");
		var bodyAb = orderAb.substring(orderAb.indexOf("interface ")),
			bodyBa = orderBa.substring(orderBa.indexOf("interface "));
		expect(bodyAb == bodyBa && bodyAb.indexOf("extern fn import_order_a") >= 0 && bodyAb.indexOf("extern fn import_order_b") >= 0,
			"included declarations should be complete and deterministic regardless of include order");
		var diagnostic = "";
		try
			importHeaderText("tests/ffi/unsupported_fixture.h", "x86_64-linux-gnu", ["tests/ffi"])
		catch (error:Dynamic)
			diagnostic = Std.string(error);
		expect(diagnostic.indexOf("unsupported_fixture.h:1:") >= 0 && diagnostic.indexOf("unsupported variadic function") >= 0,
			'unsupported declarations should report their source location: $diagnostic');
		var documented = importHeaderText("tests/ffi/documentation_fixture.h", "x86_64-linux-gnu", ["tests/ffi"], "clang", "docs", "Docs");
		expect(documented.indexOf("/**") >= 0
			&& documented.indexOf("An opaque resource identifier used by the documentation fixture.") >= 0,
			"Doxygen comments should be preserved in generated HXI");
		expect(documented.indexOf("@param options Creation options; the label is copied before returning.") >= 0,
			"Doxygen parameter comments should be preserved in generated HXI");
		var labeled = importHeaderText(FileSystem.fullPath("tests/ffi/documentation_fixture.h"), "x86_64-linux-gnu", ["tests/ffi"], "clang", "docs", "Docs",
			null, "tests/ffi/documentation_fixture.h");
		expect(labeled.indexOf("// Generated by Haxeon from tests/ffi/documentation_fixture.h") == 0,
			"generated HXI source labels should be stable and path-independent");
		var documentedModel = HxiParser.parse("documentation_fixture.hxi", documented),
			documentation = documentedModel.documentation;
		expect(documentation.get("docs_mode").raw.indexOf("Display mode accepted") >= 0, "generated HXI type documentation should be retained by the parser");
		expect(documentation.get("docs_mode.DOCS_MODE_DEFAULT").raw.indexOf("platform default") >= 0,
			"generated HXI enum-value documentation should be retained by the parser");
		expect(documentation.get("docs_options").raw.indexOf("Options supplied") >= 0,
			"generated HXI structure documentation should be retained by the parser");
		expect(documentation.get("docs_create").raw.indexOf("@param options") >= 0, "generated HXI documentation should be retained by the parser");
		expect(documentation.get("docs_options.count").raw.indexOf("Number of entries") >= 0,
			"generated HXI field documentation should be retained by the parser");
		var documentedProjection = HxiProjection.source(documentedModel);
		expect(documentedProjection.indexOf("Creates a documented resource.") >= 0
			&& documentedProjection.indexOf("@param options Creation options") >= 0,
			"C documentation should reach the generated Haxe projection");
		expect(documentedProjection.indexOf("Number of entries to reserve.") >= 0, "structure field documentation should reach generated Haxe accessors");
		Sys.println("PASS: Clang C headers import into deterministic raw HXI");
	}

	static function importHeaderText(header:String, target:String, includes:Array<String>, clang:String = "clang", ?library:String, ?interfaceName:String,
			?dependencies:Array<String>, ?sourceLabel:String, ?excludedHeaders:Array<String>):String {
		var model = CHeaderImporter.importHeader(header, target, includes, clang, library, interfaceName, dependencies, excludedHeaders),
			label = sourceLabel == null ? header : sourceLabel;
		return HxiWriter.write(model, generatedHeader(label, target));
	}

	static function generatedHeader(label:String, target:String):String
		return '// Generated by Haxeon from $label for $target. Do not edit.';

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
