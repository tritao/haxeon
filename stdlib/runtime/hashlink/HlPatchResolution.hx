package runtime.hashlink;

/** Haxe-resolved stable-ID and relocation slots for one HLP transaction. */
class HlPatchFunctionResolution {
	public final stableId:Int;
	public final slot:Int;
	public final relocationStableIds:Array<Int>;
	public final relocationSlots:Array<Int>;

	public function new(stableId:Int, slot:Int, relocationStableIds:Array<Int>, relocationSlots:Array<Int>) {
		if (stableId < 0 || slot < 0 || relocationStableIds == null || relocationSlots == null || relocationStableIds.length != relocationSlots.length)
			throw "HashLink patch function resolution is incomplete";
		this.stableId = stableId;
		this.slot = slot;
		this.relocationStableIds = relocationStableIds;
		this.relocationSlots = relocationSlots;
	}
}

/** Haxe-owned resolution plan used while projecting a patch for native publication. */
class HlRuntimePatchResolution {
	public final functions:Array<HlPatchFunctionResolution>;

	public function new(functions:Array<HlPatchFunctionResolution>) {
		if (functions == null || functions.length == 0)
			throw "HashLink patch resolution requires at least one function";
		this.functions = functions;
	}
}
