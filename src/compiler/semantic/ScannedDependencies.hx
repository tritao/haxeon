package compiler.semantic;

/** Source names and built-in companions referenced by a module's syntax. */
class ScannedDependencies {
	public final required:Map<String, Bool> = [];
	public final optional:Map<String, Bool> = [];
	public final companionOwners:Map<String, Bool> = [];

	public function new() {}
}
