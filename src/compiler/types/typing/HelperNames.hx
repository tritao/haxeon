package compiler.types.typing;

import compiler.core.TextDigest;
import compiler.semantic.SemanticSignature;
import compiler.types.Type.CompilerType;

/**
 * The names of generated helpers (equality, hashing) for one compilation, by prefix and the spelled type they are for. A
 * name ends in a digest of that spelling; typing asks for the same few many times, so each is hashed once.
 */
class HelperNames {
	final byPrefix:Map<String, Map<String, String>> = [];

	public function new() {}

	/** The helper named by `prefix` for `type`: `nameOf(prefix, type)`, computed once per spelling. */
	public function named(prefix:String, type:CompilerType):String {
		var names = byPrefix.get(prefix);
		if (names == null) {
			names = [];
			byPrefix.set(prefix, names);
		}
		var signature = SemanticSignature.type(type), name = names.get(signature);
		if (name == null) {
			name = spelled(prefix, signature);
			names.set(signature, name);
		}
		return name;
	}

	/** The helper named by `prefix` for `type`, computed without a cache. */
	public static function nameOf(prefix:String, type:CompilerType):String
		return spelled(prefix, SemanticSignature.type(type));

	static function spelled(prefix:String, signature:String):String
		return prefix + TextDigest.sha256(signature).substr(0, 32);
}
