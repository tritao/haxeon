package runtime.hashlink;

import runtime.memory.RawPtr;

/** Stable native view handed to a future HashLink publication boundary. */
typedef HlMetadataPublication = {
	final types:RawPtr<RawPtr<HlType>>;
	final typeCount:Int;
	final typeCapacity:Int;
	final moduleContext:RawPtr<HlModuleContext>;
}

/** Builds and seals one Haxe-owned HashLink metadata generation. */
class HlMetadataGeneration {
	public final arena:HlTypeArena;
	public final builder:HlTypeBuilder;
	final typeTable:HlTypeTable;
	var moduleContext:RawPtr<HlModuleContext> = RawPtr.nullPtr();
	var published:Bool = false;
	var disposed:Bool = false;

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

	/** Define the function dispatch tables used by HashLink-derived metadata. */
	public function defineModule(functions:Array<RawPtr<UInt8>>, functionTypes:Array<RawPtr<HlType>>):RawPtr<HlModuleContext> {
		requireBuilding();
		if (!moduleContext.isNull())
			throw "HashLink metadata generation module context is already defined";
		moduleContext = builder.moduleContext(functions, functionTypes);
		return moduleContext;
	}

	/** Initialize HashLink-derived metadata and return its stable pointer-table view. */
	public function publish():HlMetadataPublication {
		requireBuilding();
		if (moduleContext.isNull())
			throw "HashLink metadata generation requires a module context before publication";
		for (index in 0...typeTable.length())
			initialize(typeTable.get(index));
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
			moduleContext: moduleContext
		};
	}

	/** Release HashLink-derived and arena-owned metadata. Repeated disposal is safe. */
	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		arena.dispose();
		moduleContext = RawPtr.nullPtr();
	}

	function initialize(type:RawPtr<HlType>):Void {
		var kind:HlTypeKind = cast type.ref.kind;
		if (kind == HlTypeKind.Object || kind == HlTypeKind.Struct)
			HlTypeBridge.native_type_data_size(type);
		else if (kind == HlTypeKind.Enum)
			HlTypeBridge.native_type_initialize_enum(type, moduleContext);
		else if (kind == HlTypeKind.Virtual)
			HlTypeBridge.native_type_initialize_virtual(type, moduleContext);
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
}
