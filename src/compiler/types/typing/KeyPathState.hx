package compiler.types.typing;

/** The key paths typed code uses: resolved definitions, the constant arguments of specialized bodies and compositions made. */
class KeyPathState {
	/** Resolved field sequences used by path operations and descriptor generation. */
	public final definitions:Map<String, KeyPathTyping.KeyPathDefinition> = [];

	/** The key path constants each generic specialization was made for, by specialization name. */
	final parameters:Map<String, KeyPathConstants> = [];

	public function new() {}

	/** The key path literal each of `specialization`'s parameters is bound to, by parameter name, or null. */
	public function constantsOf(specialization:String):Null<Map<String, String>> {
		var constants = parameters.get(specialization);
		return constants == null ? null : constants.byParameter;
	}

	/** Records the constants `specialization` was made for, outside the arena of the work that made it: the session keeps them. */
	public function setConstants(specialization:String, constants:Map<String, String>):Void
		parameters.set(specialization, compiler.core.Arena.toGlobal(new KeyPathConstants(constants)));
}

/** One specialization's key path constants; a class so the session's table holds typed values (docs/design/ARENAS.md). */
class KeyPathConstants {
	public final byParameter:Map<String, String>;

	public function new(byParameter:Map<String, String>)
		this.byParameter = byParameter;
}
