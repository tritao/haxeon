package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlTypeBridge;
import runtime.hashlink.HlTypeLayout;
import runtime.hashlink.HlFunction;
import runtime.hashlink.HlNative;
import runtime.hashlink.HlConstant;
import runtime.hashlink.HlModulePools;
import runtime.hashlink.HlDebugSection;
import runtime.hashlink.HlDebugSectionTable;
import runtime.hashlink.HlNativeCode;

/** Stable native view handed to a future HashLink publication boundary. */
typedef HlMetadataPublication = {
	final types:RawPtr<RawPtr<HlType>>;
	final typeCount:Int;
	final typeCapacity:Int;
	final contiguousTypes:RawPtr<HlType>;
	final contiguousTypeCount:Int;
	final contiguousTypeCapacity:Int;
	final usesContiguousTypes:Bool;
	final functionDescriptors:RawPtr<HlFunction>;
	final functionDescriptorCount:Int;
	final functionDescriptorCapacity:Int;
	final nativeDescriptors:RawPtr<HlNative>;
	final nativeDescriptorCount:Int;
	final nativeDescriptorCapacity:Int;
	final constants:RawPtr<HlConstant>;
	final constantCount:Int;
	final constantCapacity:Int;
	final debugSections:RawPtr<HlDebugSection>;
	final debugSectionCount:Int;
	final debugSectionCapacity:Int;
	final functionStableIds:RawPtr<Int32>;
	final functionNames:RawPtr<RawPtr<UInt8>>;
	final functionNameLengths:RawPtr<Int32>;
	final ints:RawPtr<Int32>;
	final intCount:Int;
	final floats:RawPtr<Float>;
	final floatCount:Int;
	final strings:RawPtr<RawPtr<UInt8>>;
	final stringLengths:RawPtr<Int32>;
	final ustrings:RawPtr<RawPtr<UInt16>>;
	final stringCount:Int;
	final bytes:RawPtr<UInt8>;
	final byteCount:Int;
	final bytePositions:RawPtr<Int32>;
	final bytePositionCount:Int;
	final entryPoint:Int;
	final debugFiles:RawPtr<RawPtr<UInt8>>;
	final debugFileLengths:RawPtr<Int32>;
	final debugFileCount:Int;
	final globalTypes:RawPtr<RawPtr<HlType>>;
	final globals:RawPtr<RawPtr<UInt8>>;
	final globalCount:Int;
	final functions:RawPtr<RawPtr<UInt8>>;
	final functionTypes:RawPtr<RawPtr<HlType>>;
	final functionCount:Int;
	final moduleContext:RawPtr<HlModuleContext>;
	final nativeCode:RawPtr<HlNativeCode>;
}

/** Builds and seals one Haxe-owned HashLink metadata generation. */
class HlMetadataGeneration {
	public final arena:HlTypeArena;
	public final builder:HlTypeBuilder;
	public final functionDescriptors:HlFunctionDescriptorTable;
	public final nativeDescriptors:HlNativeDescriptorTable;
	public final constantDescriptors:HlConstantTable;
	public final debugSectionDescriptors:HlDebugSectionTable;
	var modulePools:HlModulePools;
	var modulePoolsDefined:Bool = false;
	var nativeCode:RawPtr<HlNativeCode> = RawPtr.nullPtr();
	var functionStableIds:RawPtr<Int32> = RawPtr.nullPtr();
	var functionNames:RawPtr<RawPtr<UInt8>> = RawPtr.nullPtr();
	var functionNameLengths:RawPtr<Int32> = RawPtr.nullPtr();
	final typeTable:HlTypeTable;
	var functionTable:Null<HlFunctionTable>;
	var moduleContext:RawPtr<HlModuleContext> = RawPtr.nullPtr();
	var globalTypes:RawPtr<RawPtr<HlType>> = RawPtr.nullPtr();
	var globals:RawPtr<RawPtr<UInt8>> = RawPtr.nullPtr();
	var globalCount:Int = 0;
	var globalsDefined:Bool = false;
	var debugFiles:RawPtr<RawPtr<UInt8>> = RawPtr.nullPtr();
	var debugFileLengths:RawPtr<Int32> = RawPtr.nullPtr();
	var debugFileCount:Int = 0;
	var debugFileIndices:Map<String, Int> = [];
	var debugFilesDefined:Bool = false;
	var published:Bool = false;
	var publishedContiguousTypeCount:Int = 0;
	var publishedUsesContiguousTypes:Bool = false;
	var disposed:Bool = false;
	var borrowers:Int = 0;

	public function new(?blockSize:Int = 65536, ?initialTypeCapacity:Int = 8, ?typeCapacity:Int = 65536, ?functionDescriptorCapacity:Int = 8,
		?nativeDescriptorCapacity:Int = 8, ?constantCapacity:Int = 8, ?debugSectionCapacity:Int = 8) {
		arena = new HlTypeArena(blockSize, typeCapacity);
		builder = new HlTypeBuilder(arena);
		functionDescriptors = new HlFunctionDescriptorTable(arena, functionDescriptorCapacity);
		nativeDescriptors = new HlNativeDescriptorTable(arena, nativeDescriptorCapacity);
		constantDescriptors = new HlConstantTable(arena, constantCapacity);
		debugSectionDescriptors = new HlDebugSectionTable(arena, debugSectionCapacity);
		modulePools = new HlModulePools(arena, builder, [], [], [], haxe.io.Bytes.alloc(0), [], 0);
		typeTable = new HlTypeTable(arena, initialTypeCapacity);
	}

	/** Base of the contiguous Haxe-owned type-record slab. */
	public function contiguousTypePointer():RawPtr<HlType> {
		requireOpen();
		return arena.typePointer();
	}

	/** Number of reserved slots in the contiguous type-record slab. */
	public function contiguousTypeCapacity():Int {
		requireOpen();
		return arena.typeCapacityOf();
	}

	/** Append one type and return its stable module-local index. */
	public function addType(type:RawPtr<HlType>):Int {
		requireBuilding();
		return typeTable.add(type);
	}

	public function typeCount():Int {
		requireOpen();
		return typeTable.length();
	}

	public function typeCapacity():Int {
		requireOpen();
		return typeTable.capacityOf();
	}

	public function type(index:Int):RawPtr<HlType> {
		requireOpen();
		return typeTable.get(index);
	}

	/** Return the module-local index of a type pointer, or -1 when it is external. */
	public function typeIndex(type:RawPtr<HlType>):Int {
		requireOpen();
		return typeTable.indexOf(type);
	}

	/** Append one Haxe-owned HashLink function descriptor. */
	public function addFunctionDescriptor(spec:HlFunctionDescriptorSpec):RawPtr<HlFunction> {
		requireBuilding();
		return functionDescriptors.add(spec);
	}

	/** Define stable debugger identities in native function-descriptor order. */
	public function defineFunctionIdentities(stableIds:Array<Int>, names:Array<String>):Void {
		requireBuilding();
		var count = functionDescriptors.length();
		if (stableIds == null || names == null || stableIds.length != count || names.length != count)
			throw "HashLink function identity arrays must match the function descriptor table";
		if (count == 0)
			return;
		functionStableIds = arena.allocInt32Array(count);
		functionNames = arena.allocNativePointerArray(count);
		functionNameLengths = arena.allocInt32Array(count);
		for (index in 0...count) {
			if (stableIds[index] < 0)
				throw "HashLink stable function identities must be non-negative";
			for (previous in 0...index)
				if (stableIds[previous] == stableIds[index])
					throw 'Duplicate HashLink stable function identity ${stableIds[index]}';
			functionStableIds.offset(index).store(cast stableIds[index]);
			var name = names[index];
			if (name == null || name.length == 0) {
				functionNames.offset(index).store(RawPtr.nullPtr());
				functionNameLengths.offset(index).store(cast 0);
			} else {
				functionNames.offset(index).store(builder.utf8Name(name));
				functionNameLengths.offset(index).store(cast HlTypeBuilder.utf8Length(name));
			}
		}
	}

	/** Append one Haxe-owned HashLink native binding descriptor. */
	public function addNativeDescriptor(spec:HlNativeDescriptorSpec):RawPtr<HlNative> {
		requireBuilding();
		return nativeDescriptors.add(spec);
	}

	/** Append one Haxe-owned HashLink global constant descriptor. */
	public function addConstant(spec:HlConstantDescriptorSpec):RawPtr<HlConstant> {
		requireBuilding();
		return constantDescriptors.add(spec);
	}

	/** Append one Haxe-owned HashLink module debug section. */
	public function addDebugSection(spec:HlDebugSectionSpec):RawPtr<HlDebugSection> {
		requireBuilding();
		return debugSectionDescriptors.add(spec);
	}

	/** Attach the arena-owned scalar pools for one HLB module. */
	public function defineModulePools(pools:HlModulePools):Void {
		requireBuilding();
		if (pools == null || pools.arena != arena)
			throw "HashLink module pools must share the metadata arena";
		if (modulePoolsDefined)
			throw "HashLink module pools are already defined";
		modulePools = pools;
		modulePoolsDefined = true;
	}

	public function stringPointer(index:Int):RawPtr<UInt8> {
		requireOpen();
		return modulePools.string(index);
	}

	/** Return the module scalar pools, or null for hand-built metadata without an HLB module. */
	public function modulePoolsOrNull():Null<HlModulePools> {
		requireOpen();
		return modulePools;
	}

	/** Number of function dispatch slots in the module context. */
	public function functionCount():Int {
		requireOpen();
		return requireFunctionTable().length();
	}

	/** Number of bytecode function descriptors, excluding native dispatch slots. */
	public function bytecodeFunctionCount():Int {
		requireOpen();
		return functionDescriptors.length();
	}

	/** Dispatch slot of one bytecode function descriptor in descriptor order. */
	public function bytecodeFunctionSlot(index:Int):Int {
		requireOpen();
		return cast functionDescriptors.get(index).ref.findex;
	}

	/** Whether a dispatch slot is backed by a bytecode function descriptor. */
	public function isBytecodeFunctionSlot(slot:Int):Bool {
		requireOpen();
		for (index in 0...functionDescriptors.length()) {
			var findex:Int = cast functionDescriptors.get(index).ref.findex;
			if (findex == slot)
				return true;
		}
		return false;
	}

	/** Read one module function signature slot. */
	public function functionType(index:Int):RawPtr<HlType> {
		requireOpen();
		return requireFunctionTable().typeAt(index);
	}

	/** Read one module function entrypoint slot without changing its ownership. */
	public function functionPointer(index:Int):RawPtr<UInt8> {
		requireOpen();
		return requireFunctionTable().functionAt(index);
	}

	/** Define the function dispatch tables used by HashLink-derived metadata. */
	public function defineModule(functions:Array<RawPtr<UInt8>>, functionTypes:Array<RawPtr<HlType>>):RawPtr<HlModuleContext> {
		requireBuilding();
		if (!moduleContext.isNull())
			throw "HashLink metadata generation module context is already defined";
		functionTable = new HlFunctionTable(arena, functions, functionTypes);
		moduleContext = builder.moduleContextFromTable(functionTable);
		return moduleContext;
	}

	/** Define the stable UTF-8 debug-file table referenced by native function records. */
	public function defineDebugFiles(paths:Array<String>):Void {
		requireBuilding();
		if (paths == null)
			throw "HashLink metadata debug files are required";
		if (debugFilesDefined)
			throw "HashLink metadata debug-file table is already defined";
		debugFilesDefined = true;
		debugFileCount = paths.length;
		if (debugFileCount == 0)
			return;
		debugFiles = arena.allocNativePointerArray(debugFileCount);
		debugFileLengths = arena.allocInt32Array(debugFileCount);
		for (index in 0...debugFileCount) {
			var path = paths[index];
			if (path == null || debugFileIndices.exists(path))
				throw "HashLink metadata debug-file paths must be non-null and unique";
			debugFileIndices.set(path, index);
			debugFiles.offset(index).store(builder.utf8Name(path));
			debugFileLengths.offset(index).store(cast HlTypeBuilder.utf8Length(path));
		}
	}

	/** Return the native debug-file index for one published source path. */
	public function debugFileIndex(path:String):Int {
		requireOpen();
		if (!debugFilesDefined || path == null || !debugFileIndices.exists(path))
			throw 'HashLink metadata has no debug-file index for "$path"';
		return debugFileIndices.get(path);
	}

	public inline function debugFileCountOf():Int
		return debugFileCount;

	/** Allocate the shared 1-based global-value slot table used by HLB types. */
	public function defineGlobals(count:Int):RawPtr<RawPtr<UInt8>> {
		requireBuilding();
		if (count < 0)
			throw "HashLink metadata global count must be non-negative";
		if (globalsDefined)
			throw "HashLink metadata global table is already defined";
		globalsDefined = true;
		globalCount = count;
		if (count == 0)
			return globals;
		globalTypes = arena.allocTypePointerArray(count);
		for (index in 0...count)
			globalTypes.offset(index).store(RawPtr.nullPtr());
		globals = arena.allocNativePointerArray(count);
		for (index in 0...count)
			globals.offset(index).store(RawPtr.nullPtr());
		return globals;
	}

	/** Define the HLB global type table and allocate its separate value slots. */
	public function defineGlobalTypes(types:Array<RawPtr<HlType>>):RawPtr<RawPtr<UInt8>> {
		if (types == null)
			throw "HashLink metadata global types are required";
		var result = defineGlobals(types.length);
		for (index in 0...types.length)
			globalTypes.offset(index).store(types[index]);
		return result;
	}

	/** Return the arena-owned slot for a 1-based HLB global index. */
	public function globalPointer(index:Int):RawPtr<RawPtr<UInt8>> {
		requireOpen();
		if (index == 0)
			return RawPtr.nullPtr();
		if (!globalsDefined || index < 0 || index > globalCount)
			throw 'HashLink metadata global index $index is outside 1...$globalCount';
		return globals.offset(index - 1);
	}

	/** Read one HLB global type-table entry. */
	public function globalType(index:Int):RawPtr<HlType> {
		requireOpen();
		if (!globalsDefined || index < 0 || index >= globalCount)
			throw 'HashLink metadata global type index $index is outside 0...$globalCount';
		return globalTypes.offset(index).load();
	}

	/** Initialize HashLink-derived metadata and return its stable pointer-table view. */
	public function publish():HlMetadataPublication {
		requireBuilding();
		if (moduleContext.isNull())
			throw "HashLink metadata generation requires a module context before publication";
		validateDescriptorTables();
		validateDebugFiles();
		for (functionIndex in 0...functionDescriptors.length()) {
			functionDescriptors.validateCodeAt(functionIndex);
			functionDescriptors.validateDebugAt(functionIndex, debugFileCount);
		}
		HlTypeBridge.native_metadata_validate_global_types(globalTypes, globalCount, globals);
		constantDescriptors.validate(globalCount);
		HlTypeBridge.native_metadata_validate_constants(constantDescriptors.pointer(), constantDescriptors.length(), globalCount);
		HlTypeBridge.native_metadata_validate_debug_sections(debugSectionDescriptors.pointer(), debugSectionDescriptors.length());
		validateModulePools();
		HlTypeLayout.initialize(typeTable.pointer(), typeTable.length(), arena);
		var contiguousTypes = arena.typePointer(), usesContiguousTypes = typeTable.isContiguousPrefix(contiguousTypes);
		HlTypeLayout.bindFunctionDescriptors(typeTable.pointer(), typeTable.length(), functionDescriptors.pointer(), functionDescriptors.length(), moduleContext);
		if (usesContiguousTypes)
			HlTypeBridge.native_metadata_publish_contiguous_prototypes(contiguousTypes, typeTable.length(), moduleContext);
		else
			HlTypeBridge.native_metadata_publish_prototypes(typeTable.pointer(), typeTable.length(), moduleContext);
		ensureFunctionIdentities();
		buildNativeCode();
		HlTypeBridge.native_metadata_validate_code(nativeCode);
		publishedContiguousTypeCount = arena.typeCountOf();
		publishedUsesContiguousTypes = usesContiguousTypes;
		published = true;
		return snapshot();
	}

	/** Return the immutable publication view after {@link publish}. */
	public inline function isPublished():Bool {
		requireOpen();
		return published;
	}

	/** Return the immutable publication view after {@link publish}. */
	public function snapshot():HlMetadataPublication {
		requireOpen();
		if (!published)
			throw "HashLink metadata generation has not been published";
		return {
			types: typeTable.pointer(),
			typeCount: typeTable.length(),
			typeCapacity: typeTable.capacityOf(),
			contiguousTypes: arena.typePointer(),
			contiguousTypeCount: publishedContiguousTypeCount,
			contiguousTypeCapacity: arena.typeCapacityOf(),
			usesContiguousTypes: publishedUsesContiguousTypes,
			functionDescriptors: functionDescriptors.pointer(),
			functionDescriptorCount: functionDescriptors.length(),
			functionDescriptorCapacity: functionDescriptors.capacityOf(),
			nativeDescriptors: nativeDescriptors.pointer(),
			nativeDescriptorCount: nativeDescriptors.length(),
			nativeDescriptorCapacity: nativeDescriptors.capacityOf(),
			constants: constantDescriptors.pointer(),
			constantCount: constantDescriptors.length(),
			constantCapacity: constantDescriptors.capacityOf(),
			debugSections: debugSectionDescriptors.pointer(),
			debugSectionCount: debugSectionDescriptors.length(),
			debugSectionCapacity: debugSectionDescriptors.capacityOf(),
			functionStableIds: functionStableIds,
			functionNames: functionNames,
			functionNameLengths: functionNameLengths,
			ints: modulePools.ints,
			intCount: modulePools.intCount,
			floats: modulePools.floats,
			floatCount: modulePools.floatCount,
			strings: modulePools.strings,
			stringLengths: modulePools.stringLengths,
			ustrings: modulePools.ustrings,
			stringCount: modulePools.stringCount,
			bytes: modulePools.bytes,
			byteCount: modulePools.byteCount,
			bytePositions: modulePools.bytePositions,
			bytePositionCount: modulePools.bytePositionCount,
			entryPoint: modulePools.entryPoint,
			debugFiles: debugFiles,
			debugFileLengths: debugFileLengths,
			debugFileCount: debugFileCount,
			globalTypes: globalTypes,
			globals: globals,
			globalCount: globalCount,
			functions: requireFunctionTable().functionPointer(),
			functionTypes: requireFunctionTable().typePointer(),
			functionCount: requireFunctionTable().length(),
			moduleContext: moduleContext,
			nativeCode: nativeCode
		};
	}

	/** Link the published component tables into the native HashLink module record. */
	function buildNativeCode():Void {
		var code = arena.allocNativeCode();
		code.ref.version = 7;
		code.ref.intCount = cast modulePools.intCount;
		code.ref.floatCount = cast modulePools.floatCount;
		code.ref.stringCount = cast modulePools.stringCount;
		code.ref.bytePositionCount = cast modulePools.bytePositionCount;
		code.ref.typeCount = cast typeTable.length();
		code.ref.typeCapacity = cast arena.typeCapacityOf();
		code.ref.globalCount = cast globalCount;
		code.ref.nativeCount = cast nativeDescriptors.length();
		code.ref.functionCount = cast functionDescriptors.length();
		code.ref.constantCount = cast constantDescriptors.length();
		code.ref.debugSectionCount = cast debugSectionDescriptors.length();
		code.ref.entryPoint = cast modulePools.entryPoint;
		code.ref.debugFileCount = cast debugFileCount;
		code.ref.hasDebug = debugFileCount != 0;
		code.ref.ints = modulePools.ints;
		code.ref.floats = modulePools.floats;
		code.ref.strings = modulePools.strings;
		code.ref.stringLengths = modulePools.stringLengths;
		code.ref.bytes = modulePools.bytes;
		code.ref.bytePositions = modulePools.bytePositions;
		code.ref.debugFiles = debugFiles;
		code.ref.debugFileLengths = debugFileLengths;
		code.ref.ustrings = modulePools.ustrings;
		code.ref.types = arena.typePointer();
		code.ref.globals = globalTypes;
		code.ref.natives = nativeDescriptors.pointer();
		code.ref.functions = functionDescriptors.pointer();
		code.ref.functionStableIds = functionStableIds;
		code.ref.functionNames = functionNames;
		code.ref.functionNameLengths = functionNameLengths;
		code.ref.constants = constantDescriptors.pointer();
		code.ref.debugSections = debugSectionDescriptors.pointer();
		code.ref.alloc.ref.current = RawPtr.nullPtr();
		code.ref.falloc.ref.current = RawPtr.nullPtr();
		nativeCode = code;
	}

	function ensureFunctionIdentities():Void {
		var count = functionDescriptors.length();
		if (count == 0 || !functionStableIds.isNull())
			return;
		functionStableIds = arena.allocInt32Array(count);
		functionNames = arena.allocNativePointerArray(count);
		functionNameLengths = arena.allocInt32Array(count);
		for (index in 0...count) {
			functionStableIds.offset(index).store(functionDescriptors.get(index).ref.findex);
			functionNames.offset(index).store(RawPtr.nullPtr());
			functionNameLengths.offset(index).store(cast 0);
		}
	}

	function validateModulePools():Void {
		if (modulePools.entryPoint < 0)
			throw "HashLink module entry point must be non-negative";
		HlTypeBridge.native_metadata_validate_module_pools(modulePools.ints, modulePools.intCount, modulePools.floats, modulePools.floatCount,
			modulePools.strings, modulePools.stringLengths, modulePools.stringCount, modulePools.bytes, modulePools.byteCount, modulePools.bytePositions,
			modulePools.bytePositionCount, modulePools.entryPoint);
	}

	/** Validate the arena-owned source paths referenced by function debug records. */
	public function validateDebugFiles():Int {
		if (debugFileCount < 0 || (debugFileCount > 0 && debugFiles.isNull()))
			throw "HashLink debug metadata requires a debug-file table";
		for (index in 0...debugFileCount)
			if (debugFiles.offset(index).load().isNull())
				throw "HashLink debug metadata contains a null file name";
		return debugFileCount;
	}

	/** Borrow the published view until the returned lease is released. */
	public function acquire():HlMetadataLease {
		requireOpen();
		if (!published)
			throw "HashLink metadata generation has not been published";
		return new HlMetadataLease(this);
	}

	/** Number of active metadata leases. */
	public function borrowerCount():Int {
		requireOpen();
		return borrowers;
	}

	/** Release HashLink-derived and arena-owned metadata. Repeated disposal is safe. */
	public function dispose():Void {
		if (disposed)
			return;
		if (borrowers != 0)
			throw 'HashLink metadata generation has $borrowers active lease(s)';
		disposed = true;
		arena.dispose();
		moduleContext = RawPtr.nullPtr();
	}

	function requireBuilding():Void {
		requireOpen();
		if (published)
			throw "HashLink metadata generation is already published";
	}

	function requireOpen():Void {
		if (disposed)
			throw "HashLink metadata generation has been disposed";
	}

	@:allow(runtime.hashlink.HlMetadataLease)
	function retainBorrow():Void {
		requireOpen();
		borrowers++;
	}

	@:allow(runtime.hashlink.HlMetadataLease)
	function releaseBorrow():Void {
		if (borrowers == 0)
			throw "HashLink metadata generation lease count is already zero";
		borrowers--;
	}

	function requireFunctionTable():HlFunctionTable {
		if (functionTable == null)
			throw "HashLink metadata generation has no module function table";
		return functionTable;
	}

	function validateDescriptorTables():Void {
		var functions = requireFunctionTable();
		functionDescriptors.validate(functions);
		nativeDescriptors.validate(functions);
		for (functionIndex in 0...functionDescriptors.length()) {
			var functionFindex:Int = cast functionDescriptors.get(functionIndex).ref.findex;
			for (nativeIndex in 0...nativeDescriptors.length()) {
				var nativeFindex:Int = cast nativeDescriptors.get(nativeIndex).ref.findex;
				if (functionFindex == nativeFindex)
					throw 'HashLink function and native descriptors share dispatch slot $functionFindex';
			}
		}
	}
}
