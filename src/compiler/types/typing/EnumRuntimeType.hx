package compiler.types.typing;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.semantic.SemanticSignature;
import haxe.crypto.Sha256;

/** Stable runtime descriptors retain the semantic arguments of a generic boxed enum. */
class EnumRuntimeType {
	public static inline final SEPARATOR = "$enum-specialization:";

	/** Length of the hash that names a specialization, in `name` and in the helper functions made for it. */
	public static inline final HASH_LENGTH = 32;

	public static function name(type:CompilerType):Null<String>
		return switch type {
			case TNullable(inner), TAbstract(_, _, inner): name(inner);
			case TInstance(NominalKind.Enum, name, arguments):
				arguments.length == 0 ? name : name + SEPARATOR + Sha256.encode(SemanticSignature.type(type)).substr(0, HASH_LENGTH);
			default: null;
		};

	/** The hash that ends the name of an enum specialization, or null when `name` is not one. */
	public static function specializationHash(name:String):Null<String> {
		var index = name.indexOf(SEPARATOR);
		return index < 0 ? null : name.substr(index + SEPARATOR.length);
	}

	/**
		The hash of the enum specialization a generated `$enum…:<hash>` helper function serves, or null for any other function.
		The hash is the last `HASH_LENGTH` characters, so colons earlier in the name do not matter.
	**/
	public static function helperHash(functionName:String):Null<String> {
		var start = functionName.length - HASH_LENGTH;
		return StringTools.startsWith(functionName, "$enum")
			&& start > 0
			&& functionName.charAt(start - 1) == ":" ? functionName.substr(start) : null;
	}

	public static function declaration(name:String):String {
		var index = name.indexOf(SEPARATOR);
		return index < 0 ? name : name.substr(0, index);
	}
}
