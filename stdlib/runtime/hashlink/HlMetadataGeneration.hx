package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.memory.Mutex;
import runtime.hashlink.HlTypeBridge;
import runtime.hashlink.HlTypeLayout;
import runtime.hashlink.HlModulePools;
import runtime.hashlink.HlDebugSectionTable;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlCode;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlConstant;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlDebugSection;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlFunction;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlNative;
import runtime.hashlink.HlTypeArena.HlTypeArenaCheckpoint;
import runtime.hashlink.HlTypeTable.HlTypeTableCheckpoint;

/** Stable native view handed to a future HashLink publication boundary. */
typedef HlMetadataPublication = {
	final types:RawPtr<RawPtr<HlType>>;
	final typeCount:Int;
	final typeCapacity:Int;
	final contiguousTypes:RawPtr<HlType>;
	final contiguousTypeCount:Int;
	final contiguousTypeCapacity:Int;
	final usesContiguousTypes:Bool;
	final functionDescriptors:RawPtr<NativeModuleHlFunction>;
	final functionDescriptorCount:Int;
	final functionDescriptorCapacity:Int;
	final nativeDescriptors:RawPtr<NativeModuleHlNative>;
	final nativeDescriptorCount:Int;
	final nativeDescriptorCapacity:Int;
	final constants:RawPtr<NativeModuleHlConstant>;
	final constantCount:Int;
	final constantCapacity:Int;
	final debugSections:RawPtr<NativeModuleHlDebugSection>;
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
	final nativeCode:RawPtr<NativeModuleHlCode>;
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
	var nativeCode:RawPtr<NativeModuleHlCode> = RawPtr.nullPtr();
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
	var activeTypeAppend:Null<HlMetadataTypeAppend>;
	var disposed:Bool = false;
	var borrowers:Int = 0;
	final borrowerMutex:Mutex;

	public function new(?blockSize:Int = 65536, ?initialTypeCapacity:Int = 8, ?typeCapacity:Int = 65536, ?functionDescriptorCapacity:Int = 8,
		?nativeDescriptorCapacity:Int = 8, ?constantCapacity:Int = 8, ?debugSectionCapacity:Int = 8, ?kernel:HlMetadataModuleKernel) {
		arena = new HlTypeArena(blockSize, typeCapacity, kernel);
		builder = new HlTypeBuilder(arena);
		functionDescriptors = new HlFunctionDescriptorTable(arena, functionDescriptorCapacity);
		nativeDescriptors = new HlNativeDescriptorTable(arena, nativeDescriptorCapacity);
		constantDescriptors = new HlConstantTable(arena, constantCapacity);
		debugSectionDescriptors = new HlDebugSectionTable(arena, debugSectionCapacity);
		modulePools = new HlModulePools(arena, builder, [], [], [], haxe.io.Bytes.alloc(0), [], 0);
		typeTable = new HlTypeTable(arena, initialTypeCapacity);
		borrowerMutex = Mutex.create();
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

	/** Start an append-only transaction for Haxe-owned compatible patch types. */
	public function beginTypeAppend():HlMetadataTypeAppend {
		requireOpen();
		if (!published)
			throw "HashLink metadata type appends require a published generation";
		if (activeTypeAppend != null)
			throw "HashLink metadata generation already has an active type append";
		if (nativeCode.isNull() || arena.typeCountOf() != typeTable.length())
			throw "HashLink metadata type table is not a contiguous arena prefix";
		var result = new HlMetadataTypeAppend(this, arena.checkpoint(), typeTable.checkpoint(), modulePools);
		builder.openTypeAppend();
		activeTypeAppend = result;
		return result;
	}

	@:allow(runtime.hashlink.HlMetadataTypeAppend)
	function appendType(transaction:HlMetadataTypeAppend, type:RawPtr<HlType>):Int {
		requireOpen();
		if (activeTypeAppend != transaction)
			throw "HashLink metadata type append is no longer active";
		if (type.isNull())
			throw "HashLink metadata type append contains a null type";
		var index = typeTable.length();
		if (arena.typeCountOf() != index + 1 || type != arena.typePointer().offset(index))
			throw "HashLink metadata type append is not contiguous with the published type table";
		return typeTable.add(type);
	}

	@:allow(runtime.hashlink.HlMetadataTypeAppend)
	function commitTypeAppend(transaction:HlMetadataTypeAppend):Void {
		requireOpen();
		if (activeTypeAppend != transaction)
			throw "HashLink metadata type append is no longer active";
		if (nativeCode.isNull() || arena.typeCountOf() != typeTable.length())
			throw "HashLink metadata type append did not produce a contiguous type table";
		nativeCode.ref.typeCount = cast typeTable.length();
		publishedContiguousTypeCount = arena.typeCountOf();
		publishedUsesContiguousTypes = typeTable.isContiguousPrefix(arena.typePointer());
		builder.closeTypeAppend();
		activeTypeAppend = null;
	}

	@:allow(runtime.hashlink.HlMetadataTypeAppend)
	function rollbackTypeAppend(transaction:HlMetadataTypeAppend, arenaCheckpoint:HlTypeArenaCheckpoint, tableCheckpoint:HlTypeTableCheckpoint,
			previousModulePools:HlModulePools):Void {
		requireOpen();
		if (activeTypeAppend != transaction)
			return;
		typeTable.rollback(tableCheckpoint);
		arena.rollback(arenaCheckpoint);
		modulePools = previousModulePools;
		builder.closeTypeAppend();
		activeTypeAppend = null;
	}

	/** Replace the cumulative scalar pools during an active patch transaction. */
	@:allow(compiler.hl.HlNativeMetadataBuilder)
	function replaceModulePools(pools:HlModulePools):Void {
		requireOpen();
		if (!published || pools == null || pools.arena != arena)
			throw "HashLink patch pools must share a published metadata arena";
		modulePools = pools;
	}

	/** Append one Haxe-owned HashLink function descriptor. */
	public function addFunctionDescriptor(spec:HlFunctionDescriptorSpec):RawPtr<NativeModuleHlFunction> {
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
	public function addNativeDescriptor(spec:HlNativeDescriptorSpec):RawPtr<NativeModuleHlNative> {
		requireBuilding();
		return nativeDescriptors.add(spec);
	}

	/** Append one Haxe-owned HashLink global constant descriptor. */
	public function addConstant(spec:HlConstantDescriptorSpec):RawPtr<NativeModuleHlConstant> {
		requireBuilding();
		return constantDescriptors.add(spec);
	}

	/** Append one Haxe-owned HashLink module debug section. */
	public function addDebugSection(spec:HlDebugSectionSpec):RawPtr<NativeModuleHlDebugSection> {
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

	/** Return HashLink's pre-module-init 1-based global reference representation. */
	public function globalIndex(index:Int):RawPtr<RawPtr<UInt8>> {
		requireOpen();
		if (!globalsDefined || index <= 0 || index > globalCount)
			throw 'HashLink metadata global index $index is outside 1...$globalCount';
		var reference:RawPtr<RawPtr<UInt8>> = RawPtr.nullPtr();
		return reference.byteOffset(index);
	}

	/** Read one HLB global type-table entry. */
	public function globalType(index:Int):RawPtr<HlType> {
		requireOpen();
		if (!globalsDefined || index < 0 || index >= globalCount)
			throw 'HashLink metadata global type index $index is outside 0...$globalCount';
		return globalTypes.offset(index).load();
	}

	/** Validate global type records and keep object/enum values inside this generation's slot table. */
	public function validateGlobalTypes():Int {
		if (globalCount < 0 || (globalCount > 0 && (globalTypes.isNull() || globals.isNull())))
			throw "HashLink global metadata requires matching type and value tables";
		for (index in 0...globalCount) {
			var type = globalTypes.offset(index).load();
			if (type.isNull())
				throw 'HashLink global metadata contains an invalid type at index $index';
			var kind:Int = cast type.ref.kind, minimumKind:Int = cast(HlTypeKind.VoidType, Int), maximumKind:Int = cast(HlTypeKind.Guid, Int);
			if (kind < minimumKind || kind > maximumKind)
				throw 'HashLink global metadata contains an invalid type at index $index';
			if (kind == HlTypeKind.Object || kind == HlTypeKind.Struct) {
				var object = type.ref.data.ref.obj;
				if (object.isNull())
					throw 'HashLink global metadata contains an invalid object type at index $index';
				if (!object.ref.globalValue.isNull() && !containsGlobalSlot(object.ref.globalValue))
					throw "HashLink object global value is outside the published value table";
			} else if (kind == HlTypeKind.Enum) {
				var enumData = type.ref.data.ref.enumType;
				if (enumData.isNull())
					throw 'HashLink global metadata contains an invalid enum type at index $index';
				if (!enumData.ref.globalValue.isNull() && !containsGlobalSlot(enumData.ref.globalValue))
					throw "HashLink enum global value is outside the published value table";
			}
		}
		return globalCount;
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
		validateGlobalTypes();
		constantDescriptors.validate(globalCount);
		debugSectionDescriptors.validate();
		validateModulePools();
		HlTypeLayout.validate(typeTable.pointer(), typeTable.length());
		HlTypeLayout.bindModuleContexts(typeTable.pointer(), typeTable.length(), moduleContext);
		HlTypeLayout.initialize(typeTable.pointer(), typeTable.length(), arena);
		HlTypeLayout.bindFunctionDescriptors(typeTable.pointer(), typeTable.length(), functionDescriptors.pointer(), functionDescriptors.length(), moduleContext);
		var usesContiguousTypes = typeTable.isContiguousPrefix(arena.typePointer());
		HlTypeLayout.bindFunctionReferences(functionDescriptors.pointer(), functionDescriptors.length());
		HlTypeLayout.bindEntrypointDescriptor(functionDescriptors.pointer(), functionDescriptors.length(), modulePools.entryPoint, builder);
		ensureFunctionIdentities();
		buildNativeCode();
		validateNativeCode();
		publishedContiguousTypeCount = arena.typeCountOf();
		publishedUsesContiguousTypes = usesContiguousTypes;
		builder.seal();
		functionDescriptors.seal();
		nativeDescriptors.seal();
		constantDescriptors.seal();
		debugSectionDescriptors.seal();
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

	/** Validate the complete Haxe-owned code record before handing it to HashLink. */
	public function validateNativeCode():Int {
		if (nativeCode.isNull())
			throw "HashLink native code metadata must not be null";
		var code = nativeCode, version:Int = cast code.ref.version, intCount:Int = cast code.ref.intCount, floatCount:Int = cast code.ref.floatCount,
			stringCount:Int = cast code.ref.stringCount, bytePositionCount:Int = cast code.ref.bytePositionCount, typeCount:Int = cast code.ref.typeCount,
			typeCapacity:Int = cast code.ref.typeCapacity, globalCount:Int = cast code.ref.globalCount, nativeCount:Int = cast code.ref.nativeCount,
			functionCount:Int = cast code.ref.functionCount, constantCount:Int = cast code.ref.constantCount,
			debugSectionCount:Int = cast code.ref.debugSectionCount, entryPoint:Int = cast code.ref.entryPoint, debugFileCount:Int = cast code.ref.debugFileCount;
		if (version <= 1 || version > 7 || intCount < 0 || floatCount < 0 || stringCount < 0 || bytePositionCount < 0 || typeCount < 0
			|| typeCapacity < typeCount || globalCount < 0 || nativeCount < 0 || functionCount < 0 || constantCount < 0 || debugSectionCount < 0
			|| entryPoint < 0 || debugFileCount < 0)
			throw "HashLink native code metadata contains invalid counts";
		if ((intCount > 0 && code.ref.ints.isNull()) || (floatCount > 0 && code.ref.floats.isNull())
			|| (stringCount > 0 && (code.ref.strings.isNull() || code.ref.stringLengths.isNull() || code.ref.ustrings.isNull()))
			|| (bytePositionCount > 0 && (code.ref.bytes.isNull() || code.ref.bytePositions.isNull()))
			|| (typeCount > 0 && code.ref.types.isNull()) || (globalCount > 0 && code.ref.globals.isNull())
			|| (nativeCount > 0 && code.ref.natives.isNull())
			|| (functionCount > 0 && (code.ref.functions.isNull() || code.ref.functionStableIds.isNull()
				|| code.ref.functionNames.isNull() || code.ref.functionNameLengths.isNull()))
			|| (constantCount > 0 && code.ref.constants.isNull()) || (debugSectionCount > 0 && code.ref.debugSections.isNull())
			|| (debugFileCount > 0 && (code.ref.debugFiles.isNull() || code.ref.debugFileLengths.isNull())))
			throw "HashLink native code metadata contains incomplete tables";
		for (index in 0...functionCount) {
			var stableId:Int = cast code.ref.functionStableIds.offset(index).load(), nameLength:Int = cast code.ref.functionNameLengths.offset(index).load();
			if (stableId < 0 || nameLength < 0 || (nameLength > 0 && code.ref.functionNames.offset(index).load().isNull()))
				throw "HashLink native code metadata contains an invalid function identity";
			for (previous in 0...index) {
				var previousStableId:Int = cast code.ref.functionStableIds.offset(previous).load();
				if (previousStableId == stableId)
					throw "HashLink native code metadata contains duplicate function identities";
			}
		}
		return typeCount;
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

	public function validateModulePools():Int {
		return modulePools.validate();
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

	function containsGlobalSlot(value:RawPtr<RawPtr<UInt8>>):Bool {
		for (index in 0...globalCount)
			if (globals.offset(index) == value || globalIndex(index + 1) == value)
				return true;
		return false;
	}

	/** Borrow the published view until the returned lease is released. */
	public function acquire():HlMetadataLease {
		borrowerMutex.acquire();
		try {
			requireOpen();
			if (!published)
				throw "HashLink metadata generation has not been published";
			var result = new HlMetadataLease(this, snapshot());
			borrowers++;
			borrowerMutex.release();
			return result;
		} catch (error:Dynamic) {
			borrowerMutex.release();
			throw error;
		}
	}

	/** Number of active metadata leases. */
	public function borrowerCount():Int {
		borrowerMutex.acquire();
		try {
			requireOpen();
			var result = borrowers;
			borrowerMutex.release();
			return result;
		} catch (error:Dynamic) {
			borrowerMutex.release();
			throw error;
		}
	}

	/** Release HashLink-derived and arena-owned metadata. Repeated disposal is safe. */
	public function dispose():Void {
		borrowerMutex.acquire();
		try {
			if (disposed) {
				borrowerMutex.release();
				return;
			}
			if (borrowers != 0)
				throw 'HashLink metadata generation has $borrowers active lease(s)';
			disposed = true;
			borrowerMutex.release();
		} catch (error:Dynamic) {
			borrowerMutex.release();
			throw error;
		}
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
	function releaseBorrow():Void {
		borrowerMutex.acquire();
		try {
			if (borrowers == 0)
				throw "HashLink metadata generation lease count is already zero";
			borrowers--;
			borrowerMutex.release();
		} catch (error:Dynamic) {
			borrowerMutex.release();
			throw error;
		}
	}

	/** Dispose this generation only when no lease can acquire concurrently. */
	@:allow(runtime.hashlink.HlMetadataRegistry)
	function disposeIfUnborrowed():Bool {
		borrowerMutex.acquire();
		try {
			if (disposed || borrowers != 0) {
				borrowerMutex.release();
				return false;
			}
			disposed = true;
			borrowerMutex.release();
		} catch (error:Dynamic) {
			borrowerMutex.release();
			throw error;
		}
		arena.dispose();
		moduleContext = RawPtr.nullPtr();
		return true;
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
