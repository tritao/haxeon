package runtime.hashlink;

import runtime.memory.RawPtr;

/** Haxe-owned stable-ID to native dispatch-slot projection for one module. */
class HlRuntimeDispatchTable {
	public final stableIds:RawPtr<Int32>;
	public final slots:RawPtr<Int32>;
	public final count:Int;
	public final initializerSlot:Int;
	final slotByStableId:Map<Int, Int>;

	public function new(arena:HlTypeArena, stableIdValues:Array<Int>, slotValues:Array<Int>, initializerSlot:Int, ?functionCount:Int = -1) {
		if (arena == null || stableIdValues == null || slotValues == null || stableIdValues.length != slotValues.length || initializerSlot < -1
			|| functionCount < -1)
			throw "HashLink runtime dispatch metadata requires matching stable-ID and slot arrays";
		count = stableIdValues.length;
		this.initializerSlot = initializerSlot;
		slotByStableId = [];
		stableIds = count == 0 ? RawPtr.nullPtr() : arena.allocInt32Array(count);
		slots = count == 0 ? RawPtr.nullPtr() : arena.allocInt32Array(count);
		var seenStableIds:Map<Int, Bool> = [],
			seenSlots:Map<Int, Bool> = [];
		for (index in 0...count) {
			var stableId = stableIdValues[index],
				slot = slotValues[index];
			if (stableId < 0 || slot < 0 || functionCount >= 0 && slot >= functionCount || seenStableIds.exists(stableId) || seenSlots.exists(slot))
				throw "HashLink runtime dispatch identities must be unique and non-negative";
			seenStableIds.set(stableId, true);
			seenSlots.set(slot, true);
			slotByStableId.set(stableId, slot);
			stableIds.offset(index).store(cast stableId);
			slots.offset(index).store(cast slot);
		}
		if (initializerSlot >= 0 && !seenSlots.exists(initializerSlot))
			throw "HashLink runtime dispatch initializer must reference an identity slot";
		if (functionCount >= 0 && initializerSlot >= functionCount)
			throw "HashLink runtime dispatch initializer is outside the function table";
	}

	public inline function stableIdAt(index:Int):Int {
		checkIndex(index);
		return cast stableIds.offset(index).load();
	}

	public inline function slotAt(index:Int):Int {
		checkIndex(index);
		return cast slots.offset(index).load();
	}

	/** Resolve one stable function identity without entering native code. */
	public function slotOf(stableId:Int):Int {
		return slotByStableId.exists(stableId) ? slotByStableId.get(stableId) : -1;
	}

	function checkIndex(index:Int):Void
		if (index < 0 || index >= count)
			throw 'HashLink runtime dispatch index $index is outside 0...$count';
}
