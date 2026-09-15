package runtime.hashlink;

import runtime.memory.RawPtr;

/** One stable HashLink function identity and the code version currently at its slot. */
typedef HlFunctionVersion = {
	final stableId:Int;
	final slot:Int;
	final typeIndex:Int;
	final entrypoint:RawPtr<UInt8>;
	final generation:Int;
}

/** Replacement for one function identity; the slot is retained by the table. */
typedef HlFunctionReplacement = {
	final stableId:Int;
	final typeIndex:Int;
	final entrypoint:RawPtr<UInt8>;
}

/** Constructor shape for one immutable function-version entry. */
typedef HlFunctionVersionEntry = {
	final stableId:Int;
	final slot:Int;
	final typeIndex:Int;
	final entrypoint:RawPtr<UInt8>;
}

/**
	Immutable Haxe-side view of stable function identities and their current versions.

	The native dispatch table remains owned by {@link HlFunctionTable}. This class
	owns the policy mapping around it: stable IDs survive slot relocation, while a
	patch changes only an entrypoint and never changes a function's signature index.
*/
class HlFunctionVersionTable {
	public final generation:Int;
	final versions:Array<HlFunctionVersion>;
	final stableIndices:Map<Int, Int> = [];
	final slotIndices:Map<Int, Int> = [];

	public function new(entries:Array<HlFunctionVersionEntry>, ?generation:Int = 0) {
		if (entries == null)
			throw "HashLink function version entries are required";
		if (generation < 0)
			throw "HashLink function version generation must be non-negative";
		this.generation = generation;
		versions = [];
		for (entry in entries) {
			if (entry.stableId < 0 || entry.slot < 0 || entry.typeIndex < 0)
				throw "HashLink function version identities must be non-negative";
			if (stableIndices.exists(entry.stableId))
				throw 'Duplicate HashLink stable function ID ${entry.stableId}';
			if (slotIndices.exists(entry.slot))
				throw 'Duplicate HashLink function slot ${entry.slot}';
			var index = versions.length;
			versions.push({
				stableId: entry.stableId,
				slot: entry.slot,
				typeIndex: entry.typeIndex,
				entrypoint: entry.entrypoint,
				generation: generation
			});
			stableIndices.set(entry.stableId, index);
			slotIndices.set(entry.slot, index);
		}
	}

	/**
		Build the stable-ID view from a metadata generation's native function table.

		Stable IDs are supplied in module slot order by the loader/compiler; entrypoint
		addresses and signature indices are read from the same generation, preventing
		the policy table from drifting away from the native metadata table.
	*/
	public static function fromMetadata(metadata:HlMetadataGeneration, stableIds:Array<Int>, ?generation:Int = 0):HlFunctionVersionTable {
		if (metadata == null || stableIds == null)
			throw "HashLink function versions require metadata and stable IDs";
		var slots:Array<Int> = [];
		if (stableIds.length == metadata.functionCount()) {
			for (slot in 0...stableIds.length)
				slots.push(slot);
		} else if (stableIds.length == metadata.bytecodeFunctionCount()) {
			for (index in 0...stableIds.length)
				slots.push(metadata.bytecodeFunctionSlot(index));
		} else {
			throw "HashLink stable IDs and metadata function slots have different lengths";
		}
		var entries:Array<HlFunctionVersionEntry> = [];
		for (index in 0...stableIds.length) {
			var slot = slots[index];
			var signature = metadata.functionType(slot), typeIndex = metadata.typeIndex(signature);
			if (typeIndex < 0)
				throw 'HashLink function signature at slot $slot is external to its metadata generation';
			entries.push({
				stableId: stableIds[slot],
				slot: slot,
				typeIndex: typeIndex,
				entrypoint: metadata.functionPointer(slot)
			});
		}
		return new HlFunctionVersionTable(entries, generation);
	}

	public inline function length():Int
		return versions.length;

	/** Return the version for a stable ID, or null when the identity is absent. */
	public function find(stableId:Int):Null<HlFunctionVersion> {
		var index = stableIndices.get(stableId);
		return index == null ? null : versions[index];
	}

	/** Return the version at a native dispatch slot, or null when the slot is absent. */
	public function findSlot(slot:Int):Null<HlFunctionVersion> {
		var index = slotIndices.get(slot);
		return index == null ? null : versions[index];
	}

	public function at(stableId:Int):HlFunctionVersion {
		var version = find(stableId);
		if (version == null)
			throw 'Unknown HashLink stable function ID $stableId';
		return version;
	}

	/** Return a copy suitable for diagnostics or construction of another snapshot. */
	public function entries():Array<HlFunctionVersion> {
		return versions.copy();
	}

	/** Re-stamp the immutable entries when the surrounding metadata is published. */
	public function withGeneration(nextGeneration:Int):HlFunctionVersionTable {
		if (nextGeneration < generation)
			throw 'HashLink function generation cannot move backwards from $generation';
		var next:Array<HlFunctionVersionEntry> = [];
		for (version in versions)
			next.push({
				stableId: version.stableId,
				slot: version.slot,
				typeIndex: version.typeIndex,
				entrypoint: version.entrypoint
			});
		return new HlFunctionVersionTable(next, nextGeneration);
	}

	/**
		Create the next function-version snapshot by replacing existing stable IDs.

		A patch may change code addresses, but stable slots and signature indices are
		part of the live module contract and therefore cannot change in place.
	*/
	public function replace(replacements:Array<HlFunctionReplacement>, nextGeneration:Int):HlFunctionVersionTable {
		if (nextGeneration <= generation)
			throw 'HashLink function generation must advance from $generation';
		if (replacements == null || replacements.length == 0)
			throw "HashLink function replacements are required";
		var replacementById:Map<Int, HlFunctionReplacement> = [];
		for (replacement in replacements) {
			var current = at(replacement.stableId);
			if (replacement.typeIndex != current.typeIndex)
				throw 'HashLink function signature changed for stable ID ${replacement.stableId}';
			if (replacementById.exists(replacement.stableId))
				throw 'Duplicate HashLink function replacement ${replacement.stableId}';
			replacementById.set(replacement.stableId, replacement);
		}
		var next:Array<HlFunctionVersionEntry> = [];
		for (version in versions) {
			var replacement = replacementById.get(version.stableId);
			next.push({
				stableId: version.stableId,
				slot: version.slot,
				typeIndex: version.typeIndex,
				entrypoint: replacement == null ? version.entrypoint : replacement.entrypoint
			});
		}
		return new HlFunctionVersionTable(next, nextGeneration);
	}
}
