package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlTypeBridge;
import runtime.hashlink.HlTypeLayout;
import runtime.hashlink.HlFunction;
import runtime.hashlink.HlNative;

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
	final globalTypes:RawPtr<RawPtr<HlType>>;
	final globals:RawPtr<RawPtr<UInt8>>;
	final globalCount:Int;
	final functions:RawPtr<RawPtr<UInt8>>;
	final functionTypes:RawPtr<RawPtr<HlType>>;
	final functionCount:Int;
	final moduleContext:RawPtr<HlModuleContext>;
}

/** Builds and seals one Haxe-owned HashLink metadata generation. */
class HlMetadataGeneration {
	public final arena:HlTypeArena;
	public final builder:HlTypeBuilder;
	public final functionDescriptors:HlFunctionDescriptorTable;
	public final nativeDescriptors:HlNativeDescriptorTable;
	final typeTable:HlTypeTable;
	var functionTable:Null<HlFunctionTable>;
	var moduleContext:RawPtr<HlModuleContext> = RawPtr.nullPtr();
	var globalTypes:RawPtr<RawPtr<HlType>> = RawPtr.nullPtr();
	var globals:RawPtr<RawPtr<UInt8>> = RawPtr.nullPtr();
	var globalCount:Int = 0;
	var globalsDefined:Bool = false;
	var published:Bool = false;
	var publishedContiguousTypeCount:Int = 0;
	var publishedUsesContiguousTypes:Bool = false;
	var disposed:Bool = false;
	var borrowers:Int = 0;

	public function new(?blockSize:Int = 65536, ?initialTypeCapacity:Int = 8, ?typeCapacity:Int = 65536, ?functionDescriptorCapacity:Int = 8,
		?nativeDescriptorCapacity:Int = 8) {
		arena = new HlTypeArena(blockSize, typeCapacity);
		builder = new HlTypeBuilder(arena);
		functionDescriptors = new HlFunctionDescriptorTable(arena, functionDescriptorCapacity);
		nativeDescriptors = new HlNativeDescriptorTable(arena, nativeDescriptorCapacity);
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

	/** Append one Haxe-owned HashLink native binding descriptor. */
	public function addNativeDescriptor(spec:HlNativeDescriptorSpec):RawPtr<HlNative> {
		requireBuilding();
		return nativeDescriptors.add(spec);
	}

	/** Number of function dispatch slots in the module context. */
	public function functionCount():Int {
		requireOpen();
		return requireFunctionTable().length();
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
		HlTypeLayout.initialize(typeTable.pointer(), typeTable.length(), arena);
		var contiguousTypes = arena.typePointer(), usesContiguousTypes = typeTable.isContiguousPrefix(contiguousTypes);
		if (usesContiguousTypes)
			HlTypeBridge.native_metadata_bind_contiguous_function_descriptors(contiguousTypes, typeTable.length(), functionDescriptors.pointer(), functionDescriptors.length(), moduleContext);
		else
			HlTypeBridge.native_metadata_bind_function_descriptors(typeTable.pointer(), typeTable.length(), functionDescriptors.pointer(), functionDescriptors.length(), moduleContext);
		if (usesContiguousTypes)
			HlTypeBridge.native_metadata_publish_contiguous_prototypes(contiguousTypes, typeTable.length(), moduleContext);
		else
			HlTypeBridge.native_metadata_publish_prototypes(typeTable.pointer(), typeTable.length(), moduleContext);
		publishedContiguousTypeCount = arena.typeCountOf();
		publishedUsesContiguousTypes = usesContiguousTypes;
		published = true;
		return snapshot();
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
			globalTypes: globalTypes,
			globals: globals,
			globalCount: globalCount,
			functions: requireFunctionTable().functionPointer(),
			functionTypes: requireFunctionTable().typePointer(),
			functionCount: requireFunctionTable().length(),
			moduleContext: moduleContext
		};
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
