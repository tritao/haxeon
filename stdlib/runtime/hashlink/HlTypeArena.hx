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

/** Owns stable unmanaged storage for Haxe-constructed HashLink metadata. */
class HlTypeArena {
	final storage:Arena;

	public function new(?blockSize:Int = 65536)
		storage = new Arena(blockSize);

	public inline function allocType():RawPtr<HlType>
		return storage.alloc();

	public inline function allocTypeData():RawPtr<HlTypeData>
		return storage.alloc();

	public inline function allocTypeFunction():RawPtr<HlTypeFunction>
		return storage.alloc();

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

	/** Invalidate every metadata pointer while retaining the arena blocks. */
	public inline function reset():Void
		storage.reset();

	/** Release all metadata storage. Repeated disposal is safe. */
	public inline function dispose():Void
		storage.dispose();
}
