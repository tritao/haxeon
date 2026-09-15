package runtime.hashlink;

import runtime.memory.Arena;
import runtime.memory.RawPtr;
import runtime.hashlink.HlType;
import runtime.hashlink.HlTypeData;
import runtime.hashlink.HlTypeFunction;
import runtime.hashlink.HlTypeObject.HlTypeEnum;
import runtime.hashlink.HlTypeObject.HlTypeVirtual;
import runtime.hashlink.HlTypeObject.HlObjectField;
import runtime.hashlink.HlTypeObject.HlObjectProto;
import runtime.hashlink.HlTypeObject.HlEnumConstruct;
import runtime.hashlink.HlTypeObject;
import runtime.hashlink.HlModuleContext;
import runtime.hashlink.HlRuntimeObject;
import runtime.hashlink.HlRuntimeObject.HlFieldLookup;

/** Owns stable unmanaged storage for Haxe-constructed HashLink metadata. */
class HlTypeArena {
	final storage:Arena;
	final typeStorage:Arena;
	final typeEntries:RawPtr<HlType>;
	final typeCapacity:Int;
	final moduleContexts:Array<RawPtr<HlModuleContext>> = [];
	var typeCount:Int = 0;

	public function new(?blockSize:Int = 65536, ?typeCapacity:Int = 65536) {
		if (typeCapacity <= 0)
			throw "HashLink type arena capacity must be positive";
		storage = new Arena(blockSize);
		typeStorage = new Arena(blockSize);
		this.typeCapacity = typeCapacity;
		typeEntries = typeStorage.alloc(typeCapacity);
	}

	public function allocType():RawPtr<HlType> {
		if (typeCount >= typeCapacity)
			throw 'HashLink type arena exhausted its $typeCapacity type-record slots';
		return typeEntries.offset(typeCount++);
	}

	/** Base of the stable contiguous type-record slab. */
	public inline function typePointer():RawPtr<HlType>
		return typeEntries;

	/** Reserved number of contiguous type-record slots. */
	public inline function typeCapacityOf():Int
		return typeCapacity;

	/** Number of type records acquired from the contiguous slab. */
	public inline function typeCountOf():Int
		return typeCount;

	public inline function allocTypeData():RawPtr<HlTypeData>
		return storage.alloc();

	public inline function allocTypeFunction():RawPtr<HlTypeFunction>
		return storage.alloc();

	public inline function allocTypePointerArray(count:Int):RawPtr<RawPtr<HlType>>
		return storage.alloc(count);

	public inline function allocNativePointerArray(count:Int):RawPtr<RawPtr<UInt8>>
		return storage.alloc(count);

	public inline function allocTypeObjectArray(count:Int):RawPtr<HlTypeObject>
		return storage.alloc(count);

	public inline function allocEnumConstructArray(count:Int):RawPtr<HlEnumConstruct>
		return storage.alloc(count);

	public inline function allocObjectFieldArray(count:Int):RawPtr<HlObjectField>
		return storage.alloc(count);

	public inline function allocObjectProtoArray(count:Int):RawPtr<HlObjectProto>
		return storage.alloc(count);

	public inline function allocInt32Array(count:Int):RawPtr<Int32>
		return storage.alloc(count);

	public inline function allocUInt32Array(count:Int):RawPtr<UInt32>
		return storage.alloc(count);

	public inline function allocUtf16Array(count:Int):RawPtr<UInt16>
		return storage.alloc(count);

	public inline function allocTypeObject():RawPtr<HlTypeObject>
		return storage.alloc();

	public inline function allocTypeEnum():RawPtr<HlTypeEnum>
		return storage.alloc();

	public inline function allocTypeVirtual():RawPtr<HlTypeVirtual>
		return storage.alloc();

	public inline function allocEnumConstruct():RawPtr<HlEnumConstruct>
		return storage.alloc();

	public inline function allocObjectField():RawPtr<HlObjectField>
		return storage.alloc();

	public inline function allocObjectProto():RawPtr<HlObjectProto>
		return storage.alloc();

	public inline function allocModuleContext():RawPtr<HlModuleContext>
		return storage.alloc();

	public inline function allocRuntimeObject():RawPtr<HlRuntimeObject>
		return storage.alloc();

	public inline function allocRuntimeBindingArray(count:Int):RawPtr<HlRuntimeBinding>
		return storage.alloc(count);

	public inline function allocFieldLookupArray(count:Int):RawPtr<HlFieldLookup>
		return storage.alloc(count);

	/** Register a module context whose derived HashLink allocations share this arena's lifetime. */
	@:allow(runtime.hashlink.HlTypeBuilder)
	function ownModuleContext(context:RawPtr<HlModuleContext>):Void
		moduleContexts.push(context);

	/** Invalidate every metadata pointer while retaining the arena blocks. */
	public function reset():Void {
		disposeModuleContexts();
		storage.reset();
		typeStorage.reset();
		typeCount = 0;
	}

	/** Release all metadata storage. Repeated disposal is safe. */
	public function dispose():Void {
		disposeModuleContexts();
		storage.dispose();
		typeStorage.dispose();
	}

	function disposeModuleContexts():Void {
		for (context in moduleContexts)
			HlTypeBridge.native_module_context_dispose(context);
		moduleContexts.resize(0);
	}
}
