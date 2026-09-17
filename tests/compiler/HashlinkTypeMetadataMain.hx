import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.ffi.CHeaderImporter;
import compiler.ffi.HxiAbi;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiValidator;
import compiler.ffi.HxiWriter;
import compiler.runtime.CompilerIntrinsics;
import compiler.types.TypedAst.TypedExpressionKind;
import sys.io.File;

/** Verifies the first Haxe-owned C-layout model for HashLink type metadata. */
class HashlinkTypeMetadataMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("HashlinkTypeMetadata.hx",
			'import runtime.hashlink.HlType; import runtime.hashlink.HlTypeData; '
			+ 'import runtime.hashlink.HlTypeFunction; import runtime.hashlink.HlTypeFunction.HlTypeClosureType; '
			+ 'import runtime.hashlink.HlTypeFunction.HlTypeClosure; import runtime.hashlink.HlTypeObject; '
			+ 'import runtime.hashlink.HlTypeObject.HlObjectField; import runtime.hashlink.HlTypeObject.HlObjectProto; '
			+ 'import runtime.hashlink.HlTypeObject.HlTypeVirtual; import runtime.hashlink.HlTypeObject.HlTypeEnum; '
			+ 'import runtime.hashlink.HlTypeObject.HlEnumConstruct; import runtime.hashlink.HlModuleContext; '
			+
			'import runtime.hashlink.HlRuntimeObject; import runtime.hashlink.HlRuntimeObject.HlFieldLookup; import runtime.hashlink.HlRuntimeObject.HlRuntimeBinding; '
			+ 'import runtime.hashlink.HlRuntimeObject.HlVirtualValue; '
			+ 'import runtime.hashlink.HashLinkTypeBindings.NativeHlType; '
			+
			'import runtime.hashlink.HlFunction; import runtime.hashlink.HlFunction.HlFunctionField; import runtime.hashlink.HlNative; import runtime.hashlink.HlConstant; '
			+ 'import runtime.hashlink.HlDebugSection; import runtime.hashlink.HlNativeCode; '
			+ 'import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlFunction; import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlNative; '
			+
			'import runtime.hashlink.HlPatchDebug.HlSourceSpan; import runtime.hashlink.HlPatchDebug.HlSourceSnapshot; import runtime.hashlink.HlPatchDebug.HlRuntimePatchDebug; '
			+
			'import runtime.hashlink.HlPatchInput.HlRuntimePatchInstruction; import runtime.hashlink.HlPatchInput.HlRuntimePatchFunctionInput; import runtime.hashlink.HlPatchInput.HlRuntimePatchInput; '
			+ 'import runtime.hashlink.HlPatchPools.HlPatchPools; '
			+ 'function typeSize():Int return sizeof<HlType>(); '
			+ 'function boundTypeSize():Int return sizeof<NativeHlType>(); '
			+ 'function typeDataSize():Int return sizeof<HlTypeData>(); '
			+ 'function typeDataOffset():Int return offsetof<HlType>("data"); '
			+ 'function functionSize():Int return sizeof<HlTypeFunction>(); '
			+ 'function closureTypeSize():Int return sizeof<HlTypeClosureType>(); '
			+ 'function closureSize():Int return sizeof<HlTypeClosure>(); '
			+ 'function functionClosureOffset():Int return offsetof<HlTypeFunction>("closure"); '
			+ 'function objectSize():Int return sizeof<HlTypeObject>(); '
			+ 'function objectRuntimeOffset():Int return offsetof<HlTypeObject>("runtime"); '
			+ 'function fieldSize():Int return sizeof<HlObjectField>(); '
			+ 'function fieldLookupSize():Int return sizeof<HlFieldLookup>(); '
			+ 'function virtualValueSize():Int return sizeof<HlVirtualValue>(); '
			+ 'function protoSize():Int return sizeof<HlObjectProto>(); '
			+ 'function virtualSize():Int return sizeof<HlTypeVirtual>(); '
			+ 'function enumSize():Int return sizeof<HlTypeEnum>(); '
			+ 'function enumConstructSize():Int return sizeof<HlEnumConstruct>(); '
			+ 'function moduleContextSize():Int return sizeof<HlModuleContext>(); '
			+ 'function runtimeObjectSize():Int return sizeof<HlRuntimeObject>(); '
			+ 'function runtimeObjectLookupOffset():Int return offsetof<HlRuntimeObject>("lookup"); '
			+ 'function runtimeObjectInterfacesOffset():Int return offsetof<HlRuntimeObject>("interfaces"); '
			+ 'function runtimeBindingSize():Int return sizeof<HlRuntimeBinding>(); '
			+ 'function functionDescriptorSize():Int return sizeof<HlFunction>(); '
			+ 'function boundFunctionDescriptorSize():Int return sizeof<NativeModuleHlFunction>(); '
			+ 'function functionDescriptorFieldOffset():Int return offsetof<HlFunction>("field"); '
			+ 'function functionFieldSize():Int return sizeof<HlFunctionField>(); '
			+ 'function nativeDescriptorSize():Int return sizeof<HlNative>(); '
			+ 'function boundNativeDescriptorSize():Int return sizeof<NativeModuleHlNative>(); '
			+ 'function constantSize():Int return sizeof<HlConstant>(); '
			+ 'function debugSectionSize():Int return sizeof<HlDebugSection>(); '
			+ 'function nativeCodeSize():Int return sizeof<HlNativeCode>(); '
			+ 'function patchInstructionSize():Int return sizeof<HlRuntimePatchInstruction>(); '
			+ 'function patchPoolsSize():Int return sizeof<HlPatchPools>(); '
			+ 'function sourceSpanSize():Int return sizeof<HlSourceSpan>(); '
			+ 'function sourceSnapshotSize():Int return sizeof<HlSourceSnapshot>(); '
			+ 'function patchDebugSize():Int return sizeof<HlRuntimePatchDebug>(); '
			+ 'function patchFunctionInputSize():Int return sizeof<HlRuntimePatchFunctionInput>(); '
			+ 'function patchInputSize():Int return sizeof<HlRuntimePatchInput>(); '
			+ 'function main():Int return typeSize() + typeDataSize() + typeDataOffset() + functionSize() + objectSize();');
		compiler.compile("HashlinkTypeMetadata");
		var functions = compiler.lastTypedProgram.functions;
		var imported = HxiParser.parse("HashLinkMetadata.hxi", File.getContent("stdlib/runtime/hashlink/HashLinkMetadata.hxi"));
		HxiValidator.validate(imported, []);
		var importedAbi = HxiAbi.forInterface(imported), layoutPairs = [
			{
				nativeName: "hl_alloc",
				haxeName: "runtime.hashlink.HlAllocation",
				fields: [{nativeName: "cur", haxeName: "current"}]
			},
			{
				nativeName: "hl_field_lookup",
				haxeName: "runtime.hashlink.HlFieldLookup",
				fields: [
					{nativeName: "t", haxeName: "type"},
					{nativeName: "hashed_name", haxeName: "hashedName"},
					{nativeName: "field_index", haxeName: "fieldIndex"}
				]
			},
			{
				nativeName: "vvirtual",
				haxeName: "runtime.hashlink.HlVirtualValue",
				fields: [
					{nativeName: "t", haxeName: "type"},
					{nativeName: "value", haxeName: "value"},
					{nativeName: "next", haxeName: "next"}
				]
			},
			{
				nativeName: "hl_module_context",
				haxeName: "runtime.hashlink.HlModuleContext",
				fields: [
					{nativeName: "alloc", haxeName: "alloc"},
					{nativeName: "functions_ptrs", haxeName: "functionsPtrs"},
					{nativeName: "functions_types", haxeName: "functionsTypes"}
				]
			},
			{
				nativeName: "hl_type_fun_closure_type",
				haxeName: "runtime.hashlink.HlTypeClosureType",
				fields: [{nativeName: "kind", haxeName: "kind"}, {nativeName: "p", haxeName: "pointer"}]
			},
			{
				nativeName: "hl_type_fun_closure",
				haxeName: "runtime.hashlink.HlTypeClosure",
				fields: [
					{nativeName: "args", haxeName: "args"},
					{nativeName: "ret", haxeName: "ret"},
					{nativeName: "nargs", haxeName: "nargs"},
					{nativeName: "parent", haxeName: "parent"}
				]
			},
			{
				nativeName: "hl_type_fun",
				haxeName: "runtime.hashlink.HlTypeFunction",
				fields: [
					{nativeName: "args", haxeName: "args"},
					{nativeName: "ret", haxeName: "ret"},
					{nativeName: "nargs", haxeName: "nargs"},
					{nativeName: "parent", haxeName: "parent"},
					{nativeName: "closure_type", haxeName: "closureType"},
					{nativeName: "closure", haxeName: "closure"}
				]
			},
			{
				nativeName: "hl_obj_field",
				haxeName: "runtime.hashlink.HlObjectField",
				fields: [
					{nativeName: "name", haxeName: "name"},
					{nativeName: "t", haxeName: "type"},
					{nativeName: "hashed_name", haxeName: "hashedName"}
				]
			},
			{
				nativeName: "hl_obj_proto",
				haxeName: "runtime.hashlink.HlObjectProto",
				fields: [
					{nativeName: "name", haxeName: "name"},
					{nativeName: "findex", haxeName: "findex"},
					{nativeName: "pindex", haxeName: "pindex"},
					{nativeName: "hashed_name", haxeName: "hashedName"}
				]
			},
			{
				nativeName: "hl_runtime_binding",
				haxeName: "runtime.hashlink.HlRuntimeBinding",
				fields: [
					{nativeName: "ptr", haxeName: "pointer"},
					{nativeName: "closure", haxeName: "closure"},
					{nativeName: "fid", haxeName: "fieldId"}
				]
			},
			{
				nativeName: "hl_runtime_obj",
				haxeName: "runtime.hashlink.HlRuntimeObject",
				fields: [
					{nativeName: "t", haxeName: "type"},
					{nativeName: "nfields", haxeName: "nfields"},
					{nativeName: "nproto", haxeName: "nproto"},
					{nativeName: "size", haxeName: "size"},
					{nativeName: "nmethods", haxeName: "nmethods"},
					{nativeName: "nbindings", haxeName: "nbindings"},
					{nativeName: "pad_size", haxeName: "padSize"},
					{nativeName: "largest_field", haxeName: "largestField"},
					{nativeName: "hasPtr", haxeName: "hasPtr"},
					{nativeName: "methods", haxeName: "methods"},
					{nativeName: "fields_indexes", haxeName: "fieldIndexes"},
					{nativeName: "bindings", haxeName: "bindings"},
					{nativeName: "parent", haxeName: "parent"},
					{nativeName: "toStringFun", haxeName: "toStringFun"},
					{nativeName: "compareFun", haxeName: "compareFun"},
					{nativeName: "castFun", haxeName: "castFun"},
					{nativeName: "getFieldFun", haxeName: "getFieldFun"},
					{nativeName: "nlookup", haxeName: "nlookup"},
					{nativeName: "ninterfaces", haxeName: "ninterfaces"},
					{nativeName: "lookup", haxeName: "lookup"},
					{nativeName: "interfaces", haxeName: "interfaces"}
				]
			},
			{
				nativeName: "hl_type_obj",
				haxeName: "runtime.hashlink.HlTypeObject",
				fields: [
					{nativeName: "nfields", haxeName: "nfields"},
					{nativeName: "nproto", haxeName: "nproto"},
					{nativeName: "nbindings", haxeName: "nbindings"},
					{nativeName: "name", haxeName: "name"},
					{nativeName: "super", haxeName: "superType"},
					{nativeName: "fields", haxeName: "fields"},
					{nativeName: "proto", haxeName: "proto"},
					{nativeName: "bindings", haxeName: "bindings"},
					{nativeName: "global_value", haxeName: "globalValue"},
					{nativeName: "m", haxeName: "module"},
					{nativeName: "rt", haxeName: "runtime"}
				]
			},
			{
				nativeName: "hl_type_virtual",
				haxeName: "runtime.hashlink.HlTypeVirtual",
				fields: [
					{nativeName: "fields", haxeName: "fields"},
					{nativeName: "nfields", haxeName: "nfields"},
					{nativeName: "dataSize", haxeName: "dataSize"},
					{nativeName: "indexes", haxeName: "indexes"},
					{nativeName: "lookup", haxeName: "lookup"}
				]
			},
			{
				nativeName: "hl_enum_construct",
				haxeName: "runtime.hashlink.HlEnumConstruct",
				fields: [
					{nativeName: "name", haxeName: "name"},
					{nativeName: "nparams", haxeName: "nparams"},
					{nativeName: "params", haxeName: "params"},
					{nativeName: "size", haxeName: "size"},
					{nativeName: "hasptr", haxeName: "hasPtr"},
					{nativeName: "offsets", haxeName: "offsets"}
				]
			},
			{
				nativeName: "hl_type_enum",
				haxeName: "runtime.hashlink.HlTypeEnum",
				fields: [
					{nativeName: "name", haxeName: "name"},
					{nativeName: "nconstructs", haxeName: "nconstructs"},
					{nativeName: "constructs", haxeName: "constructs"},
					{nativeName: "global_value", haxeName: "globalValue"}
				]
			},
			{
				nativeName: "hl_type",
				haxeName: "runtime.hashlink.HlType",
				fields: [
					{nativeName: "kind", haxeName: "kind"},
					{nativeName: "vobj_proto", haxeName: "vobjProto"},
					{nativeName: "mark_bits", haxeName: "markBits"},
					{nativeName: "gc_owner", haxeName: "gcOwner"}
				]
			}
		];
		for (pair in layoutPairs) {
			var importedLayout = importedAbi.layout(HxiType.Named(pair.nativeName)),
				haxeLayout = requireLayout(requireClass(compiler.lastTypedProgram.classes, pair.haxeName).nativeLayouts, "portable-abi64");
			expect(importedLayout != null && importedLayout.size == haxeLayout.size && importedLayout.align == haxeLayout.alignment,
				'${pair.haxeName} must match the header-derived HXI layout for ${pair.nativeName}');
			for (fieldPair in pair.fields) {
				var importedOffset = importedFieldOffset(imported, pair.nativeName, fieldPair.nativeName),
					haxeOffset = requireField(haxeLayout.fields, fieldPair.haxeName).offset;
				expect(importedOffset == haxeOffset,
					'${pair.haxeName}.${fieldPair.haxeName} must match the header-derived offset for ${pair.nativeName}.${fieldPair.nativeName}');
			}
		}
		expect(constantReturn(functions, "HashlinkTypeMetadata.typeSize") == 40, "hl_type must match the 64-bit C header size");
		expect(constantReturn(functions, "HashlinkTypeMetadata.boundTypeSize") == 40, "the runtime HXI binding alias must preserve hl_type layout");
		expect(constantReturn(functions, "HashlinkTypeMetadata.typeDataSize") == 8, "hl_type's anonymous union must be pointer-sized");
		expect(constantReturn(functions, "HashlinkTypeMetadata.typeDataOffset") == 8, "hl_type's union must follow the kind field with ABI alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.functionSize") == 80, "hl_type_fun must preserve nested aggregate padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.closureTypeSize") == 16, "hl_type_fun.closure_type must preserve pointer alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.closureSize") == 32, "hl_type_fun.closure must preserve nested aggregate padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.functionClosureOffset") == 48, "hl_type_fun.closure must follow closure_type");
		expect(constantReturn(functions, "HashlinkTypeMetadata.objectSize") == 80, "hl_type_obj must preserve pointer alignment and tail padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.objectRuntimeOffset") == 72, "hl_type_obj.runtime must preserve pointer offsets");
		expect(constantReturn(functions, "HashlinkTypeMetadata.fieldSize") == 24, "hl_obj_field must preserve pointer alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.fieldLookupSize") == 16, "hl_field_lookup must preserve pointer alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.virtualValueSize") == 24, "vvirtual must preserve its linked-list pointer layout");
		expect(constantReturn(functions, "HashlinkTypeMetadata.protoSize") == 24, "hl_obj_proto must preserve tail padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.virtualSize") == 32, "hl_type_virtual must preserve lookup pointer alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.enumSize") == 32, "hl_type_enum must preserve global value alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.enumConstructSize") == 40, "hl_enum_construct must preserve bool padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.moduleContextSize") == 24, "hl_module_context must preserve pointer slots");
		expect(constantReturn(functions, "HashlinkTypeMetadata.runtimeObjectSize") == 120, "hl_runtime_obj must preserve callback slots and trailing tables");
		expect(constantReturn(functions, "HashlinkTypeMetadata.runtimeObjectLookupOffset") == 104, "hl_runtime_obj.lookup must follow the callback slots");
		expect(constantReturn(functions, "HashlinkTypeMetadata.runtimeObjectInterfacesOffset") == 112,
			"hl_runtime_obj.interfaces must preserve the trailing pointer slot");
		expect(constantReturn(functions, "HashlinkTypeMetadata.runtimeBindingSize") == 24, "hl_runtime_binding must preserve tail padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.functionDescriptorSize") == 80, "hl_function must preserve descriptor padding");
		expect(constantReturn(functions, "HashlinkTypeMetadata.boundFunctionDescriptorSize") == 80,
			"the runtime module binding alias must preserve hl_function layout");
		expect(constantReturn(functions, "HashlinkTypeMetadata.functionDescriptorFieldOffset") == 72, "hl_function.field must preserve the named union offset");
		expect(constantReturn(functions, "HashlinkTypeMetadata.functionFieldSize") == 8, "hl_function.field must remain pointer-sized");
		expect(constantReturn(functions, "HashlinkTypeMetadata.nativeDescriptorSize") == 32, "hl_native must preserve descriptor alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.boundNativeDescriptorSize") == 32,
			"the runtime module binding alias must preserve hl_native layout");
		expect(constantReturn(functions, "HashlinkTypeMetadata.constantSize") == 16, "hl_constant must preserve descriptor alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.debugSectionSize") == 24, "hl_debug_section must preserve payload pointer alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.nativeCodeSize") == 224, "hl_code must preserve the complete module-record layout");
		expect(constantReturn(functions, "HashlinkTypeMetadata.patchInstructionSize") == 16, "hl_patch_instruction must preserve operand pointer alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.patchPoolsSize") == 56, "hl_patch_pools must preserve scalar pool pointer alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.sourceSpanSize") == 36, "hl_source_span must preserve its packed scalar layout");
		expect(constantReturn(functions, "HashlinkTypeMetadata.sourceSnapshotSize") == 16, "hl_source_snapshot must preserve content pointer alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.patchDebugSize") == 32, "hl_patch_debug must preserve nested metadata pointer alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.patchFunctionInputSize") == 80,
			"hl_patch_function must preserve decoded instruction metadata alignment");
		expect(constantReturn(functions, "HashlinkTypeMetadata.patchInputSize") == 152, "hl_patch_input must preserve the full decoded patch model layout");
		var moduleNames = [
			"hl_op",
			"hl_alloc",
			"hl_function",
			"hl_function_field",
			"hl_native",
			"hl_opcode",
			"hl_constant",
			"hl_debug_section",
			"hl_code",
			"hl_patch_instruction",
			"hl_patch_pools",
			"hl_source_span",
			"hl_source_snapshot",
			"hl_patch_debug",
			"hl_patch_function",
			"hl_patch_input"
		],
			moduleModel = CHeaderImporter.importHeader("vendor/hashlink/src/hlmodule.h", "x86_64-linux-gnu", ["vendor/hashlink/src"], "clang",
				"haxeon_runtime", "HashLinkModuleMetadata", null, null, moduleNames),
			moduleSource = HxiWriter.write(moduleModel, '// Generated by Haxeon from vendor/hashlink/src/hlmodule.h for x86_64-linux-gnu. Do not edit.'),
			checkedInModuleSource = File.getContent("stdlib/runtime/hashlink/HashLinkModuleMetadata.hxi"),
			parsedModule = HxiParser.parse("hashlink-module.hxi", checkedInModuleSource), moduleAbi = HxiAbi.forInterface(parsedModule), moduleLayoutPairs = [
				{
					nativeName: "hl_alloc",
					haxeName: "runtime.hashlink.HlAllocation",
					fields: [{nativeName: "cur", haxeName: "current"}]
				},
				{
					nativeName: "hl_constant",
					haxeName: "runtime.hashlink.HlConstant",
					fields: [
						{nativeName: "global", haxeName: "global"},
						{nativeName: "nfields", haxeName: "nfields"},
						{nativeName: "fields", haxeName: "fields"}
					]
				},
				{
					nativeName: "hl_function",
					haxeName: "runtime.hashlink.HlFunction",
					fields: [
						{nativeName: "findex", haxeName: "findex"},
						{nativeName: "type", haxeName: "type"},
						{nativeName: "obj", haxeName: "object"},
						{nativeName: "field", haxeName: "field"}
					]
				},
				{
					nativeName: "hl_function_field",
					haxeName: "runtime.hashlink.HlFunctionField",
					fields: [
						{nativeName: "name", haxeName: "name"},
						{nativeName: "ref", haxeName: "reference"}
					]
				},
				{
					nativeName: "hl_native",
					haxeName: "runtime.hashlink.HlNative",
					fields: [
						{nativeName: "lib", haxeName: "library"},
						{nativeName: "name", haxeName: "name"},
						{nativeName: "t", haxeName: "type"},
						{nativeName: "findex", haxeName: "findex"}
					]
				},
				{
					nativeName: "hl_opcode",
					haxeName: "runtime.hashlink.HlOpcode",
					fields: [
						{nativeName: "op", haxeName: "op"},
						{nativeName: "p1", haxeName: "p1"},
						{nativeName: "p2", haxeName: "p2"},
						{nativeName: "p3", haxeName: "p3"},
						{nativeName: "extra", haxeName: "extra"}
					]
				},
				{
					nativeName: "hl_debug_section",
					haxeName: "runtime.hashlink.HlDebugSection",
					fields: [
						{nativeName: "kind", haxeName: "kind"},
						{nativeName: "version", haxeName: "version"},
						{nativeName: "flags", haxeName: "flags"},
						{nativeName: "size", haxeName: "size"},
						{nativeName: "data", haxeName: "data"}
					]
				},
				{
					nativeName: "hl_code",
					haxeName: "runtime.hashlink.HlNativeCode",
					fields: [
						{nativeName: "version", haxeName: "version"},
						{nativeName: "ntypes", haxeName: "typeCount"},
						{nativeName: "types_capacity", haxeName: "typeCapacity"},
						{nativeName: "entrypoint", haxeName: "entryPoint"},
						{nativeName: "hasdebug", haxeName: "hasDebug"},
						{nativeName: "types", haxeName: "types"},
						{nativeName: "globals", haxeName: "globals"},
						{nativeName: "functions", haxeName: "functions"},
						{nativeName: "debugsections", haxeName: "debugSections"},
						{nativeName: "falloc", haxeName: "falloc"}
					]
				},
				{
					nativeName: "hl_patch_instruction",
					haxeName: "runtime.hashlink.HlRuntimePatchInstruction",
					fields: [
						{nativeName: "opcode", haxeName: "opcode"},
						{nativeName: "operand_count", haxeName: "operandCount"},
						{nativeName: "operands", haxeName: "operands"}
					]
				},
				{
					nativeName: "hl_patch_pools",
					haxeName: "runtime.hashlink.HlPatchPools",
					fields: [
						{nativeName: "int_count", haxeName: "intCount"},
						{nativeName: "float_count", haxeName: "floatCount"},
						{nativeName: "string_count", haxeName: "stringCount"},
						{nativeName: "ints", haxeName: "ints"},
						{nativeName: "floats", haxeName: "floats"},
						{nativeName: "strings", haxeName: "strings"},
						{nativeName: "string_lens", haxeName: "stringLengths"},
						{nativeName: "ustrings", haxeName: "ustrings"}
					]
				},
				{
					nativeName: "hl_source_span",
					haxeName: "runtime.hashlink.HlSourceSpan",
					fields: [
						{nativeName: "file", haxeName: "file"},
						{nativeName: "line", haxeName: "line"},
						{nativeName: "column", haxeName: "column"},
						{nativeName: "end_line", haxeName: "endLine"},
						{nativeName: "end_column", haxeName: "endColumn"},
						{nativeName: "source_hash", haxeName: "sourceHash"},
						{nativeName: "start", haxeName: "start"},
						{nativeName: "end", haxeName: "end"},
						{nativeName: "flags", haxeName: "flags"}
					]
				},
				{
					nativeName: "hl_source_snapshot",
					haxeName: "runtime.hashlink.HlSourceSnapshot",
					fields: [
						{nativeName: "source_hash", haxeName: "sourceHash"},
						{nativeName: "length", haxeName: "length"},
						{nativeName: "content", haxeName: "content"}
					]
				},
				{
					nativeName: "hl_patch_debug",
					haxeName: "runtime.hashlink.HlRuntimePatchDebug",
					fields: [
						{nativeName: "function_count", haxeName: "functionCount"},
						{nativeName: "debug_spans", haxeName: "spans"},
						{nativeName: "source_snapshot_count", haxeName: "snapshotCount"},
						{nativeName: "source_snapshots", haxeName: "snapshots"}
					]
				},
				{
					nativeName: "hl_patch_function",
					haxeName: "runtime.hashlink.HlRuntimePatchFunctionInput",
					fields: [
						{nativeName: "type", haxeName: "type"},
						{nativeName: "stable_id", haxeName: "stableId"},
						{nativeName: "findex", haxeName: "slot"},
						{nativeName: "register_count", haxeName: "registerCount"},
						{nativeName: "registers", haxeName: "registers"},
						{nativeName: "instruction_count", haxeName: "instructionCount"},
						{nativeName: "instructions", haxeName: "instructions"},
						{nativeName: "relocation_count", haxeName: "relocationCount"},
						{nativeName: "relocation_instructions", haxeName: "relocationInstructions"},
						{nativeName: "relocation_stable_ids", haxeName: "relocationStableIds"},
						{nativeName: "debug_count", haxeName: "debugCount"},
						{nativeName: "debug_spans", haxeName: "debugSpans"}
					]
				},
				{
					nativeName: "hl_patch_input",
					haxeName: "runtime.hashlink.HlRuntimePatchInput",
					fields: [
						{nativeName: "module_id", haxeName: "moduleId"},
						{nativeName: "base_revision", haxeName: "baseRevision"},
						{nativeName: "revision", haxeName: "revision"},
						{nativeName: "int_prefix_hash", haxeName: "intPrefixHash"},
						{nativeName: "float_prefix_hash", haxeName: "floatPrefixHash"},
						{nativeName: "string_prefix_hash", haxeName: "stringPrefixHash"},
						{nativeName: "type_prefix_hash", haxeName: "typePrefixHash"},
						{nativeName: "base_int_count", haxeName: "baseIntCount"},
						{nativeName: "int_count", haxeName: "intCount"},
						{nativeName: "ints", haxeName: "ints"},
						{nativeName: "float_count", haxeName: "floatCount"},
						{nativeName: "base_float_count", haxeName: "baseFloatCount"},
						{nativeName: "floats", haxeName: "floats"},
						{nativeName: "string_count", haxeName: "stringCount"},
						{nativeName: "base_string_count", haxeName: "baseStringCount"},
						{nativeName: "strings", haxeName: "strings"},
						{nativeName: "string_lens", haxeName: "stringLengths"},
						{nativeName: "type_count", haxeName: "typeCount"},
						{nativeName: "base_type_count", haxeName: "baseTypeCount"},
						{nativeName: "function_count", haxeName: "functionCount"},
						{nativeName: "functions", haxeName: "functions"},
						{nativeName: "debug_file_count", haxeName: "debugFileCount"},
						{nativeName: "debug_files", haxeName: "debugFiles"},
						{nativeName: "debug_file_lens", haxeName: "debugFileLengths"},
						{nativeName: "source_snapshot_count", haxeName: "sourceSnapshotCount"},
						{nativeName: "source_snapshots", haxeName: "sourceSnapshots"}
					]
				}
			];
		HxiValidator.validate(parsedModule, []);
		for (pair in moduleLayoutPairs) {
			var importedLayout = moduleAbi.layout(HxiType.Named(pair.nativeName)),
				haxeLayout = requireLayout(requireClass(compiler.lastTypedProgram.classes, pair.haxeName).nativeLayouts, "portable-abi64");
			expect(importedLayout != null && importedLayout.size == haxeLayout.size && importedLayout.align == haxeLayout.alignment,
				'${pair.haxeName} must match the module-header layout for ${pair.nativeName}');
			for (fieldPair in pair.fields) {
				var importedOffset = importedFieldOffset(parsedModule, pair.nativeName, fieldPair.nativeName),
					haxeOffset = requireField(haxeLayout.fields, fieldPair.haxeName).offset;
				expect(importedOffset == haxeOffset,
					'${pair.haxeName}.${fieldPair.haxeName} must match the module-header offset for ${pair.nativeName}.${fieldPair.nativeName}');
			}
		}
		expect(moduleSource == checkedInModuleSource
			&& moduleSource.indexOf("struct hl_function @layout(80, 8)") >= 0
			&& moduleSource.indexOf("ref: c_int @offset(12)") >= 0
			&& moduleSource.indexOf("field: hl_function_field @offset(72)") >= 0
			&& moduleSource.indexOf("struct hl_function_field @layout(8, 8)") >= 0
			&& moduleSource.indexOf("name: ptr<const<u16>> @offset(0) @union") >= 0
			&& moduleSource.indexOf("ref: ptr<hl_function> @offset(0) @union") >= 0
			&& moduleSource.indexOf("ref: ptr<hl_function> @offset(12)") < 0
			&& moduleSource.indexOf("struct hl_native @layout(32, 8)") >= 0
			&& moduleSource.indexOf("struct hl_constant @layout(16, 8)") >= 0
			&& moduleSource.indexOf("struct hl_debug_section @layout(24, 8)") >= 0
			&& moduleSource.indexOf("struct hl_code @layout(224, 8)") >= 0
			&& moduleSource.indexOf("types_capacity: c_int @offset(24)") >= 0
			&& moduleSource.indexOf("enum hl_op : c_int") >= 0
			&& moduleSource.indexOf("struct hl_opcode @layout(24, 8)") >= 0
			&& moduleSource.indexOf("op: hl_op @offset(0)") >= 0,
			"HashLink module descriptors must import named unions without field-name collisions");
		expectError('import runtime.hashlink.HlType; import runtime.memory.RawPtr; function bad(pointer:RawPtr<HlType>):Int return pointer.ref.missing; function main():Int return 0;',
			"Unknown native field");
	}

	static function constantReturn(functions:Array<compiler.types.TypedAst.TypedFunction>, name:String):Int {
		for (fn in functions)
			if (fn.name == name && fn.statements.length == 1)
				switch fn.statements[0] {
					case TReturn(expression, _):
						switch expression.expression {
							case TIntLiteral(value): return value;
							case _: throw 'Function "$name" did not fold its layout query to an integer literal';
						}
					case _:
				}
		throw 'Missing constant-returning function "$name"';
	}

	static function requireClass(classes:Array<compiler.types.TypedAst.TypedClass>, name:String):compiler.types.TypedAst.TypedClass {
		for (declaration in classes)
			if (declaration.name == name)
				return declaration;
		throw 'Missing typed class "$name"';
	}

	static function requireLayout(layouts:Array<compiler.types.TypedAst.TypedNativeLayout>, target:String):compiler.types.TypedAst.TypedNativeLayout {
		for (layout in layouts)
			if (layout.target == target)
				return layout;
		throw 'Missing native layout for "$target"';
	}

	static function requireField(fields:Array<compiler.types.TypedAst.TypedNativeFieldLayout>, name:String):compiler.types.TypedAst.TypedNativeFieldLayout {
		for (field in fields)
			if (field.name == name)
				return field;
		throw 'Missing native field "$name"';
	}

	static function importedFieldOffset(model:compiler.ffi.HxiModel.HxiInterface, structureName:String, fieldName:String):Int {
		for (declaration in model.declarations)
			switch declaration {
				case compiler.ffi.HxiModel.HxiDeclaration.Structure(name, _, _, fields, _) if (name == structureName):
					for (field in fields)
						if (field.name == fieldName && field.offset != null)
							return field.offset;
				case _:
			}
		throw 'Missing imported offset for "$structureName.$fieldName"';
	}

	static function expectError(source:String, expected:String):Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("HashlinkTypeMetadataNegative.hx", source);
		try {
			compiler.compile("HashlinkTypeMetadataNegative");
			throw 'expected compile error containing "$expected"';
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf(expected) < 0)
				throw error;
		}
	}

	static function expect(condition:Bool, message:String):Void
		if (!condition)
			throw message;
}
