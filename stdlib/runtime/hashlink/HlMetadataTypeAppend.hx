package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlTypeArena.HlTypeArenaCheckpoint;
import runtime.hashlink.HlTypeTable.HlTypeTableCheckpoint;

/** Transactional append of compatible Haxe-owned HashLink type records. */
class HlMetadataTypeAppend {
	final generation:HlMetadataGeneration;
	final arenaCheckpoint:HlTypeArenaCheckpoint;
	final tableCheckpoint:HlTypeTableCheckpoint;
	final previousModulePools:HlModulePools;
	var active:Bool = true;

	@:allow(runtime.hashlink.HlMetadataGeneration)
	function new(generation:HlMetadataGeneration, arenaCheckpoint:HlTypeArenaCheckpoint, tableCheckpoint:HlTypeTableCheckpoint, previousModulePools:HlModulePools) {
		this.generation = generation;
		this.arenaCheckpoint = arenaCheckpoint;
		this.tableCheckpoint = tableCheckpoint;
		this.previousModulePools = previousModulePools;
	}

	/** Append one contiguous type record and return its module-local index. */
	public function add(type:RawPtr<HlType>):Int {
		if (!active)
			throw "HashLink metadata type append is already closed";
		return generation.appendType(this, type);
	}

	/** Publish the appended type records as part of the generation. */
	public function commit():Void {
		if (!active)
			throw "HashLink metadata type append is already closed";
		generation.commitTypeAppend(this);
		active = false;
	}

	/** Discard appended records and restore every arena/table cursor. */
	public function rollback():Void {
		if (!active)
			return;
		generation.rollbackTypeAppend(this, arenaCheckpoint, tableCheckpoint, previousModulePools);
		active = false;
	}
}
