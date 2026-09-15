package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlTypeBridge;
import runtime.hashlink.HlTypeLayout;

/** Stable native view handed to a future HashLink publication boundary. */
typedef HlMetadataPublication = {
	final types:RawPtr<RawPtr<HlType>>;
	final typeCount:Int;
	final typeCapacity:Int;
	final functions:RawPtr<RawPtr<UInt8>>;
	final functionTypes:RawPtr<RawPtr<HlType>>;
	final functionCount:Int;
	final moduleContext:RawPtr<HlModuleContext>;
}

/** Builds and seals one Haxe-owned HashLink metadata generation. */
class HlMetadataGeneration {
	public final arena:HlTypeArena;
	public final builder:HlTypeBuilder;
	final typeTable:HlTypeTable;
	var functionTable:Null<HlFunctionTable>;
	var moduleContext:RawPtr<HlModuleContext> = RawPtr.nullPtr();
	var published:Bool = false;
	var disposed:Bool = false;
	var borrowers:Int = 0;

	public function new(?blockSize:Int = 65536, ?initialTypeCapacity:Int = 8) {
		arena = new HlTypeArena(blockSize);
		builder = new HlTypeBuilder(arena);
		typeTable = new HlTypeTable(arena, initialTypeCapacity);
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

	/** Initialize HashLink-derived metadata and return its stable pointer-table view. */
	public function publish():HlMetadataPublication {
		requireBuilding();
		if (moduleContext.isNull())
			throw "HashLink metadata generation requires a module context before publication";
		HlTypeLayout.initialize(typeTable.pointer(), typeTable.length(), arena);
		HlTypeBridge.native_metadata_publish_prototypes(typeTable.pointer(), typeTable.length(), moduleContext);
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
}
