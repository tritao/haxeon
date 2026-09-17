import compiler.Compiler;
import compiler.ffi.CHeaderImporter;
import compiler.ffi.HxiNativeRecordEmitter;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiWriter;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiProjection;
import compiler.ffi.HxiValidator;
import compiler.runtime.CompilerIntrinsics;
import sys.FileSystem;
import sys.io.File;

class CHeaderImporterMain {
	static function main():Void {
		var firstModel = CHeaderImporter.importHeader("tests/ffi/import_fixture.h", "x86_64-linux-gnu", ["tests/ffi"]),
			first = HxiWriter.write(firstModel, generatedHeader("tests/ffi/import_fixture.h", "x86_64-linux-gnu")),
			second = importHeaderText("tests/ffi/import_fixture.h", "x86_64-linux-gnu", ["tests/ffi"]);
		expect(Std.isOfType(firstModel, HxiInterface)
			&& firstModel.name == "import_fixture_h", "C header importer should return a typed HXI interface");
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
		var hashlinkNames = [
			"hl_type_kind",
			"hl_field_lookup",
			"vvirtual",
			"hl_runtime_binding",
			"hl_runtime_obj",
			"hl_alloc",
			"hl_module_context",
			"hl_type_fun",
			"hl_obj_field",
			"hl_obj_proto",
			"hl_type_obj",
			"hl_type_virtual",
			"hl_enum_construct",
			"hl_type_enum",
			"hl_type"
		];
		var hashlinkModel = CHeaderImporter.importHeader("vendor/hashlink/src/hl.h", "x86_64-linux-gnu", ["vendor/hashlink/src"], "clang", "haxeon_runtime",
			"HashLinkMetadata", null, null, hashlinkNames),
			hashlinkSource = HxiWriter.write(hashlinkModel, generatedHeader("vendor/hashlink/src/hl.h", "x86_64-linux-gnu")),
			checkedInHashlinkSource = File.getContent("stdlib/runtime/hashlink/HashLinkMetadata.hxi"),
			parsedHashlink = HxiParser.parse("hashlink.hxi", checkedInHashlinkSource);
		HxiValidator.validate(parsedHashlink, []);
		expect(hashlinkSource == checkedInHashlinkSource
			&& hashlinkSource.indexOf("enum hl_type_kind : c_int") >= 0
			&& hashlinkSource.indexOf("struct hl_field_lookup @layout(16, 8)") >= 0
			&& hashlinkSource.indexOf("field_index: c_int @offset(12)") >= 0
			&& hashlinkSource.indexOf("struct vvirtual @layout(24, 8)") >= 0
			&& hashlinkSource.indexOf("next: ptr<vvirtual> @offset(16)") >= 0
			&& hashlinkSource.indexOf("struct hl_type @layout(40, 8)") >= 0
			&& hashlinkSource.indexOf("abs_name: ptr<const<u16>> @offset(8) @union") >= 0
			&& hashlinkSource.indexOf("struct hl_type_fun @layout(80, 8)") >= 0
			&& hashlinkSource.indexOf("struct hl_runtime_obj @layout(120, 8)") >= 0
			&& hashlinkSource.indexOf("toStringFun: ptr<void> @offset(64)") >= 0
			&& hashlinkSource.indexOf("extern fn") < 0,
			"HashLink metadata should import from the real header while keeping machine-sensitive dependencies opaque");
		var nativeRecordSource = HxiNativeRecordEmitter.emit(parsedHashlink, "runtime.hashlink.generated", "Native"),
			nativeRecordCompiler = new Compiler();
		CompilerIntrinsics.register(nativeRecordCompiler);
		nativeRecordCompiler.addSourceRoot("stdlib");
		nativeRecordCompiler.update("runtime/hashlink/generated/HashLinkNativeRecords.hx",
			nativeRecordSource +
			'function main():Int { var arena = new runtime.memory.Arena(); var pointer:RawPtr<NativeHlType> = arena.alloc(); pointer.ref.kind = 3; return pointer.ref.kind == 3 ? 42 : 1; }');
		nativeRecordCompiler.compile("runtime.hashlink.generated.HashLinkNativeRecords");
		expect(nativeRecordSource.indexOf("class NativeHlType") >= 0
			&& nativeRecordSource.indexOf("class NativeHlTypeUnionData") >= 0
			&& nativeRecordSource.indexOf("@:layout(40, 8)") >= 0
			&& nativeRecordSource.indexOf("@:offset(8)") >= 0
			&& nativeRecordSource.indexOf("public var unionData:NativeHlTypeUnionData") >= 0
			&& nativeRecordSource.indexOf("public var vobj_proto:RawPtr<RawPtr<UInt8>>") >= 0,
			"HXI structures should project into source-declared native records with RawPtr fields");
		var nativeTypeNames:Map<String, String> = [];
		for (binding in [
			{native: "hl_alloc", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlAlloc"},
			{native: "hl_field_lookup", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlFieldLookup"},
			{native: "vvirtual", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeVvirtual"},
			{native: "hl_module_context", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlModuleContext"},
			{native: "hl_obj_field", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlObjectField"},
			{native: "hl_obj_proto", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlObjectProto"},
			{native: "hl_runtime_binding", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlRuntimeBinding"},
			{native: "hl_runtime_obj", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlRuntimeObj"},
			{native: "hl_type", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlType"},
			{native: "hl_type_enum", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlTypeEnum"},
			{native: "hl_type_fun", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlTypeFun"},
			{native: "hl_type_fun_closure", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlTypeFunClosure"},
			{native: "hl_type_fun_closure_type", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlTypeFunClosureType"},
			{native: "hl_type_obj", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlTypeObj"},
			{native: "hl_type_virtual", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlTypeVirtual"},
			{native: "hl_enum_construct", haxe: "runtime.hashlink.HashLinkTypeBindings.NativeHlEnumConstruct"}
		])
			nativeTypeNames.set(binding.native, binding.haxe);
		var nativeFieldNames = hashlinkNativeFieldNames();
		var boundRecordSource = HxiNativeRecordEmitter.emit(parsedHashlink, "runtime.hashlink.bound", "Native", null, nativeTypeNames),
			boundRecordCompiler = new Compiler();
		CompilerIntrinsics.register(boundRecordCompiler);
		boundRecordCompiler.addSourceRoot("stdlib");
		boundRecordCompiler.update("runtime/hashlink/bound/HashLinkNativeBindings.hx",
			boundRecordSource + emitHashlinkBindingLayoutQueries(parsedHashlink, nativeTypeNames,
				nativeFieldNames) +
			'function main():Int { var arena = new runtime.memory.Arena(); var pointer:RawPtr<NativeHlType> = arena.alloc(); pointer.ref.kind = 3; return pointer.ref.kind == 3 ? 42 : 1; }');
		boundRecordCompiler.compile("runtime.hashlink.bound.HashLinkNativeBindings");
		verifyHashlinkBindingLayouts(boundRecordCompiler.lastTypedProgram.functions, parsedHashlink, nativeTypeNames, nativeFieldNames);
		expect(boundRecordSource.indexOf("typedef NativeHlType = runtime.hashlink.HashLinkTypeBindings.NativeHlType;") >= 0
			&& boundRecordSource.indexOf("class NativeHlType {") < 0,
			"HXI records should bind to the canonical Haxe native record without duplicating it");
		var callbackRecord = HxiParser.parse("callback-record.hxi",
			'interface CallbackRecord @target("x86_64-linux-gnu") @library("callback") { callback binary = fn(left: i32, right: i32) -> i32; struct slot @layout(8, 8) { callback: binary @offset(0); } }'),
			callbackRecordSource = HxiNativeRecordEmitter.emit(callbackRecord, "runtime.ffi.generated", "Native");
		expect(callbackRecordSource.indexOf("typedef NativeBinary = (left:Int32, right:Int32)->Int32;") >= 0
			&& callbackRecordSource.indexOf("@:layout(8, 8)") >= 0
			&& callbackRecordSource.indexOf("@:offset(0)") >= 0
			&& callbackRecordSource.indexOf("public var callback:NativeFunctionPointer<NativeBinary>") >= 0,
			"HXI callback declarations should project into typed native function-pointer slots");
		var callbackRecordCompiler = new Compiler();
		CompilerIntrinsics.register(callbackRecordCompiler);
		callbackRecordCompiler.addSourceRoot("stdlib");
		callbackRecordCompiler.update("runtime/ffi/generated/CallbackRecords.hx",
			callbackRecordSource +
			'function main():Int { var arena = new runtime.memory.Arena(); var slot:RawPtr<NativeSlot> = arena.alloc(); var callback:runtime.memory.NativeFunctionPointer<NativeBinary> = runtime.memory.NativeFunctionPointer.nullPtr(); slot.ref.callback = callback; return slot.ref.callback.isNull() && slot.ref.callback.raw().isNull() ? 42 : 1; }');
		callbackRecordCompiler.compile("runtime.ffi.generated.CallbackRecords");
		Sys.println("PASS: Clang C headers import into deterministic raw HXI");
	}

	static function hashlinkNativeFieldNames():Map<String, String> {
		var result:Map<String, String> = [];
		for (mapping in [
			{owner: "hl_alloc", native: "cur", haxe: "current"},
			{owner: "hl_field_lookup", native: "t", haxe: "type"},
			{owner: "hl_field_lookup", native: "hashed_name", haxe: "hashedName"},
			{owner: "hl_field_lookup", native: "field_index", haxe: "fieldIndex"},
			{owner: "vvirtual", native: "t", haxe: "type"},
			{owner: "vvirtual", native: "value", haxe: "value"},
			{owner: "vvirtual", native: "next", haxe: "next"},
			{owner: "hl_enum_construct", native: "name", haxe: "name"},
			{owner: "hl_enum_construct", native: "nparams", haxe: "nparams"},
			{owner: "hl_enum_construct", native: "params", haxe: "params"},
			{owner: "hl_enum_construct", native: "size", haxe: "size"},
			{owner: "hl_enum_construct", native: "hasptr", haxe: "hasPtr"},
			{owner: "hl_enum_construct", native: "offsets", haxe: "offsets"},
			{owner: "hl_module_context", native: "alloc", haxe: "alloc"},
			{owner: "hl_module_context", native: "functions_ptrs", haxe: "functionsPtrs"},
			{owner: "hl_module_context", native: "functions_types", haxe: "functionsTypes"},
			{owner: "hl_obj_field", native: "name", haxe: "name"},
			{owner: "hl_obj_field", native: "t", haxe: "type"},
			{owner: "hl_obj_field", native: "hashed_name", haxe: "hashedName"},
			{owner: "hl_obj_proto", native: "name", haxe: "name"},
			{owner: "hl_obj_proto", native: "findex", haxe: "findex"},
			{owner: "hl_obj_proto", native: "pindex", haxe: "pindex"},
			{owner: "hl_obj_proto", native: "hashed_name", haxe: "hashedName"},
			{owner: "hl_runtime_binding", native: "ptr", haxe: "pointer"},
			{owner: "hl_runtime_binding", native: "closure", haxe: "closure"},
			{owner: "hl_runtime_binding", native: "fid", haxe: "fieldId"},
			{owner: "hl_runtime_obj", native: "t", haxe: "type"},
			{owner: "hl_runtime_obj", native: "nfields", haxe: "nfields"},
			{owner: "hl_runtime_obj", native: "nproto", haxe: "nproto"},
			{owner: "hl_runtime_obj", native: "size", haxe: "size"},
			{owner: "hl_runtime_obj", native: "nmethods", haxe: "nmethods"},
			{owner: "hl_runtime_obj", native: "nbindings", haxe: "nbindings"},
			{owner: "hl_runtime_obj", native: "pad_size", haxe: "padSize"},
			{owner: "hl_runtime_obj", native: "largest_field", haxe: "largestField"},
			{owner: "hl_runtime_obj", native: "hasPtr", haxe: "hasPtr"},
			{owner: "hl_runtime_obj", native: "methods", haxe: "methods"},
			{owner: "hl_runtime_obj", native: "fields_indexes", haxe: "fieldIndexes"},
			{owner: "hl_runtime_obj", native: "bindings", haxe: "bindings"},
			{owner: "hl_runtime_obj", native: "parent", haxe: "parent"},
			{owner: "hl_runtime_obj", native: "toStringFun", haxe: "toStringFun"},
			{owner: "hl_runtime_obj", native: "compareFun", haxe: "compareFun"},
			{owner: "hl_runtime_obj", native: "castFun", haxe: "castFun"},
			{owner: "hl_runtime_obj", native: "getFieldFun", haxe: "getFieldFun"},
			{owner: "hl_runtime_obj", native: "nlookup", haxe: "nlookup"},
			{owner: "hl_runtime_obj", native: "ninterfaces", haxe: "ninterfaces"},
			{owner: "hl_runtime_obj", native: "lookup", haxe: "lookup"},
			{owner: "hl_runtime_obj", native: "interfaces", haxe: "interfaces"},
			{owner: "hl_type", native: "kind", haxe: "kind"},
			{owner: "hl_type", native: "abs_name", haxe: "data"},
			{owner: "hl_type", native: "fun", haxe: "data"},
			{owner: "hl_type", native: "obj", haxe: "data"},
			{owner: "hl_type", native: "tenum", haxe: "data"},
			{owner: "hl_type", native: "virt", haxe: "data"},
			{owner: "hl_type", native: "tparam", haxe: "data"},
			{owner: "hl_type", native: "vobj_proto", haxe: "vobjProto"},
			{owner: "hl_type", native: "mark_bits", haxe: "markBits"},
			{owner: "hl_type", native: "gc_owner", haxe: "gcOwner"},
			{owner: "hl_type_enum", native: "name", haxe: "name"},
			{owner: "hl_type_enum", native: "nconstructs", haxe: "nconstructs"},
			{owner: "hl_type_enum", native: "constructs", haxe: "constructs"},
			{owner: "hl_type_enum", native: "global_value", haxe: "globalValue"},
			{owner: "hl_type_fun", native: "args", haxe: "args"},
			{owner: "hl_type_fun", native: "ret", haxe: "ret"},
			{owner: "hl_type_fun", native: "nargs", haxe: "nargs"},
			{owner: "hl_type_fun", native: "parent", haxe: "parent"},
			{owner: "hl_type_fun", native: "closure_type", haxe: "closureType"},
			{owner: "hl_type_fun", native: "closure", haxe: "closure"},
			{owner: "hl_type_fun_closure", native: "args", haxe: "args"},
			{owner: "hl_type_fun_closure", native: "ret", haxe: "ret"},
			{owner: "hl_type_fun_closure", native: "nargs", haxe: "nargs"},
			{owner: "hl_type_fun_closure", native: "parent", haxe: "parent"},
			{owner: "hl_type_fun_closure_type", native: "kind", haxe: "kind"},
			{owner: "hl_type_fun_closure_type", native: "p", haxe: "pointer"},
			{owner: "hl_type_obj", native: "nfields", haxe: "nfields"},
			{owner: "hl_type_obj", native: "nproto", haxe: "nproto"},
			{owner: "hl_type_obj", native: "nbindings", haxe: "nbindings"},
			{owner: "hl_type_obj", native: "name", haxe: "name"},
			{owner: "hl_type_obj", native: "super", haxe: "superType"},
			{owner: "hl_type_obj", native: "fields", haxe: "fields"},
			{owner: "hl_type_obj", native: "proto", haxe: "proto"},
			{owner: "hl_type_obj", native: "bindings", haxe: "bindings"},
			{owner: "hl_type_obj", native: "global_value", haxe: "globalValue"},
			{owner: "hl_type_obj", native: "m", haxe: "module"},
			{owner: "hl_type_obj", native: "rt", haxe: "runtime"},
			{owner: "hl_type_virtual", native: "fields", haxe: "fields"},
			{owner: "hl_type_virtual", native: "nfields", haxe: "nfields"},
			{owner: "hl_type_virtual", native: "dataSize", haxe: "dataSize"},
			{owner: "hl_type_virtual", native: "indexes", haxe: "indexes"},
			{owner: "hl_type_virtual", native: "lookup", haxe: "lookup"}
		])
			result.set(mapping.owner + "." + mapping.native, mapping.haxe);
		return result;
	}

	static function emitHashlinkBindingLayoutQueries(model:HxiInterface, nativeTypeNames:Map<String, String>, fieldNames:Map<String, String>):String {
		var output = new StringBuf();
		for (declaration in model.declarations)
			switch declaration {
				case compiler.ffi.HxiModel.HxiDeclaration.Structure(name, _, _, fields, _) if (nativeTypeNames.exists(name)):
					var projectedName = nativeRecordClassName(name);
					output.add('function hxiLayout_${projectedName}_size():Int return sizeof<$projectedName>();\n');
					output.add('function hxiLayout_${projectedName}_align():Int return alignof<$projectedName>();\n');
					for (field in fields) {
						var haxeName = fieldNames.get(name + "." + field.name);
						if (haxeName == null)
							throw 'Missing canonical HashLink field mapping for "$name.${field.name}"';
						output.add('function hxiLayout_${projectedName}_${field.name}_offset():Int return offsetof<$projectedName>("$haxeName");\n');
					}
				case _:
			}
		return output.toString();
	}

	static function verifyHashlinkBindingLayouts(functions:Array<compiler.types.TypedAst.TypedFunction>, model:HxiInterface,
			nativeTypeNames:Map<String, String>, fieldNames:Map<String, String>):Void {
		for (declaration in model.declarations)
			switch declaration {
				case compiler.ffi.HxiModel.HxiDeclaration.Structure(name, size, align, fields, _) if (nativeTypeNames.exists(name)):
					var projectedName = nativeRecordClassName(name),
						functionPrefix = "runtime.hashlink.bound.HashLinkNativeBindings.hxiLayout_" + projectedName;
					expect(constantReturn(functions, functionPrefix + "_size") == size, '${projectedName} binding must preserve the imported size for $name');
					expect(constantReturn(functions, functionPrefix + "_align") == align,
						'${projectedName} binding must preserve the imported alignment for $name');
					for (field in fields) {
						var haxeName = fieldNames.get(name + "." + field.name);
						expect(constantReturn(functions, functionPrefix + "_" + field.name + "_offset") == field.offset,
							'${projectedName}.$haxeName binding must preserve the imported offset for $name.${field.name}');
					}
				case _:
			}
	}

	static function nativeRecordClassName(name:String):String {
		var result = "Native";
		for (part in name.split("_"))
			if (part.length > 0)
				result += part.substr(0, 1).toUpperCase() + part.substr(1);
		return result;
	}

	static function constantReturn(functions:Array<compiler.types.TypedAst.TypedFunction>, name:String):Int {
		for (fn in functions)
			if (fn.name == name && fn.statements.length == 1)
				switch fn.statements[0] {
					case compiler.types.TypedAst.TypedStatement.TReturn(expression, _):
						switch expression.expression {
							case compiler.types.TypedAst.TypedExpressionKind.TIntLiteral(value): return value;
							case _:
						}
					case _:
				}
		throw 'Missing constant-returning function "$name"';
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
