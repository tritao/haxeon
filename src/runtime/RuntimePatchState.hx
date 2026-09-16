package runtime;

/** Haxe-owned revision, function-version, and generation state for one module. */
class RuntimePatchState {
	public var revision(default, null):Int;
	public var functions(default, null):RuntimeFunctionVersionTable;

	final generations:Array<RuntimePatchGeneration> = [];

	public function new(revision:Int, functions:RuntimeFunctionVersionTable) {
		if (revision < 0 || functions == null || functions.generation != revision)
			throw "Runtime patch state requires a matching non-negative revision and function table";
		this.revision = revision;
		this.functions = functions;
	}

	/** Number of successfully published patch generations. */
	public inline function committedPatchCount():Int
		return generations.length;

	/** Prepare the next immutable function-version table without publishing it. */
	public function advance(stableIds:Array<Int>, nextRevision:Int):RuntimeFunctionVersionTable
		return functions.advance(stableIds, nextRevision);

	/** Publish one native-successful generation and advance Haxe policy state. */
	public function publish(generation:RuntimePatchGeneration):Void {
		if (generation == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime patch state requires a prepared generation");
		var envelope = generation.envelope;
		if (envelope.baseRevision != revision || envelope.revision <= revision || generation.functions.generation != envelope.revision)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime patch state has an invalid revision transition");
		generations.push(generation);
		functions = generation.functions;
		revision = envelope.revision;
	}
}
