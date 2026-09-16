package runtime;

/** One stable function identity and its current host-side code generation. */
class RuntimeFunctionVersion {
	public final stableId:Int;
	public final slot:Int;
	public final typeIndex:Int;
	public final generation:Int;

	@:allow(runtime.RuntimeFunctionVersionTable)
	function new(stableId:Int, slot:Int, typeIndex:Int, generation:Int) {
		this.stableId = stableId;
		this.slot = slot;
		this.typeIndex = typeIndex;
		this.generation = generation;
	}
}

/** Immutable stable-ID/function-slot view for the legacy native runtime bridge. */
class RuntimeFunctionVersionTable {
	public final generation:Int;

	final versions:Array<RuntimeFunctionVersion>;
	final stableIndices:Map<Int, Int> = [];

	public function new(entries:Array<{stableId:Int, slot:Int, typeIndex:Int}>, ?generation:Int = 0, ?entryGenerations:Map<Int, Int>) {
		if (entries == null)
			throw "Runtime function version entries are required";
		if (generation < 0)
			throw "Runtime function version generation must be non-negative";
		this.generation = generation;
		versions = [];
		for (entry in entries) {
			if (entry.stableId < 0 || entry.slot < 0 || entry.typeIndex < 0)
				throw "Runtime function version identities must be non-negative";
			if (stableIndices.exists(entry.stableId))
				throw 'Duplicate runtime stable function ID ${entry.stableId}';
			var index = versions.length,
				entryGeneration = entryGenerations == null ? null : entryGenerations.get(entry.stableId);
			versions.push(new RuntimeFunctionVersion(entry.stableId, entry.slot, entry.typeIndex, entryGeneration == null ? generation : entryGeneration));
			stableIndices.set(entry.stableId, index);
		}
	}

	public inline function length():Int
		return versions.length;

	/** Return the version for a stable ID, or null when the identity is absent. */
	public function find(stableId:Int):Null<RuntimeFunctionVersion> {
		var index = stableIndices.get(stableId);
		return index == null ? null : versions[index];
	}

	public function at(stableId:Int):RuntimeFunctionVersion {
		var version = find(stableId);
		if (version == null)
			throw 'Unknown runtime stable function ID $stableId';
		return version;
	}

	/** Return an isolated table copy for generation diagnostics. */
	public function copy():RuntimeFunctionVersionTable {
		var entries:Array<{stableId:Int, slot:Int, typeIndex:Int}> = [],
			entryGenerations:Map<Int, Int> = [];
		for (version in versions) {
			entries.push({stableId: version.stableId, slot: version.slot, typeIndex: version.typeIndex});
			entryGenerations.set(version.stableId, version.generation);
		}
		return new RuntimeFunctionVersionTable(entries, generation, entryGenerations);
	}

	/** Advance only the stable identities replaced by a successfully published patch. */
	public function advance(replacedStableIds:Array<Int>, nextGeneration:Int):RuntimeFunctionVersionTable {
		if (nextGeneration <= generation)
			throw 'Runtime function generation must advance from $generation';
		if (replacedStableIds == null || replacedStableIds.length == 0)
			throw "Runtime function replacements are required";
		var replaced:Map<Int, Bool> = [];
		for (stableId in replacedStableIds) {
			at(stableId);
			if (replaced.exists(stableId))
				throw 'Duplicate runtime function replacement $stableId';
			replaced.set(stableId, true);
		}
		var entries:Array<{stableId:Int, slot:Int, typeIndex:Int}> = [],
			entryGenerations:Map<Int, Int> = [];
		for (version in versions) {
			entries.push({stableId: version.stableId, slot: version.slot, typeIndex: version.typeIndex});
			if (!replaced.exists(version.stableId))
				entryGenerations.set(version.stableId, version.generation);
		}
		return new RuntimeFunctionVersionTable(entries, nextGeneration, entryGenerations);
	}
}
