package compiler.types.typing;

/** The key paths typed code uses: resolved definitions, the constant arguments of specialized bodies and compositions made. */
class KeyPathState {
	/** Resolved field sequences used by path operations and descriptor generation. */
	public final definitions:Map<String, KeyPathTyping.KeyPathDefinition> = [];

	/** The key path constants each generic specialization was made for, by specialization name. */
	public final parameters:Map<String, Map<String, String>> = [];

	public function new() {}
}
