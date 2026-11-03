package compiler.types.typing;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.semantic.SemanticSignature;
import haxe.crypto.Sha256;

/** Stable runtime descriptors retain the semantic arguments of a generic boxed enum. */
class EnumRuntimeType {
	public static inline final SEPARATOR = "$enum-specialization:";

	public static function name(type:CompilerType):Null<String> return switch type {
		case TNullable(inner), TAbstract(_, _, inner): name(inner);
		case TInstance(NominalKind.Enum, name, arguments):
			arguments.length == 0 ? name : name + SEPARATOR + Sha256.encode(SemanticSignature.type(type)).substr(0, 32);
		default: null;
	};

	public static function declaration(name:String):String {
		var index = name.indexOf(SEPARATOR);
		return index < 0 ? name : name.substr(0, index);
	}
}
