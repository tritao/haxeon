package runtime.hashlink;

import runtime.memory.RawPtr;

/** Haxe-owned stable-ID to native dispatch-slot projection for one module. */
class HlRuntimeDispatchTable {
	public final stableIds:RawPtr<Int32>;
	public final slots:RawPtr<Int32>;
	public final count:Int;
	public final initializerSlot:Int;

	public function new(arena:HlTypeArena, stableIdValues:Array<Int>, slotValues:Array<Int>, initializerSlot:Int) {
		if (arena == null || stableIdValues == null || slotValues == null || stableIdValues.length != slotValues.length || initializerSlot < -1)
			throw "HashLink runtime dispatch metadata requires matching stable-ID and slot arrays";
		count = stableIdValues.length;
		this.initializerSlot = initializerSlot;
		stableIds = count == 0 ? RawPtr.nullPtr() : arena.allocInt32Array(count);
		slots = count == 0 ? RawPtr.nullPtr() : arena.allocInt32Array(count);
		var seenStableIds:Map<Int, Bool> = [],
			seenSlots:Map<Int, Bool> = [];
		for (index in 0...count) {
			var stableId = stableIdValues[index],
				slot = slotValues[index];
			if (stableId < 0 || slot < 0 || seenStableIds.exists(stableId) || seenSlots.exists(slot))
				throw "HashLink runtime dispatch identities must be unique and non-negative";
			seenStableIds.set(stableId, true);
			seenSlots.set(slot, true);
			stableIds.offset(index).store(cast stableId);
			slots.offset(index).store(cast slot);
		}
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
		for (index in 0...count) {
			var currentStableId:Int = cast stableIds.offset(index).load();
			if (currentStableId == stableId) {
				var currentSlot:Int = cast slots.offset(index).load();
				return currentSlot;
			}
		}
		return -1;
	}

	function checkIndex(index:Int):Void
		if (index < 0 || index >= count)
			throw 'HashLink runtime dispatch index $index is outside 0...$count';
}
