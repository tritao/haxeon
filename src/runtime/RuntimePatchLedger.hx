package runtime;

/** Haxe-owned history and stable-function retirement policy for one module. */
class RuntimePatchLedger {
	final committed:Array<RuntimePatchGeneration> = [];
	final retired:Array<RuntimePatchGeneration> = [];
	final activeOwners:Map<Int, RuntimePatchGeneration> = [];

	public var length(get, never):Int;
	public var retiredCount(get, never):Int;

	public function new() {}

	function get_length():Int
		return committed.length;

	function get_retiredCount():Int
		return retired.length;

	/** Record one successful publication and update stable-ID ownership. */
	public function publish(generation:RuntimePatchGeneration):RuntimePatchGeneration {
		if (generation == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime patch ledger requires a generation");
		for (stableId in generation.functionStableIds) {
			var previous = activeOwners.get(stableId);
			if (previous != null) {
				previous.replaceFunction();
				if (previous.isRetired && retired.indexOf(previous) < 0)
					retired.push(previous);
			}
			activeOwners.set(stableId, generation);
		}
		committed.push(generation);
		return generation;
	}
}
