package compiler.ir;

import compiler.ir.Ir.IrType;

/** Internal bit transport for nominal scalar carriers; this never performs a source-level cast. */
class IrScalarWordBits {
	public static inline final PACK = "$word:scalar-pack";
	public static inline final UNPACK = "$word:scalar-unpack";

	public static function matches(name:String):Bool return name == PACK || name == UNPACK;

	public static function scalar(type:IrType):Bool return switch type {
		case RawPtr, TypeRef, Abstract("native_callback"): true;
		default: false;
	};

	public static function valid(name:String, input:IrType, output:IrType):Bool {
		if (name == PACK) return switch [input, output] {
			case [EnumTag(_), I32]: true;
			default: scalar(input) && IrVerifier.sameType(output, I64);
		};
		if (name == UNPACK) return switch [input, output] {
			case [I32, EnumTag(_)]: true;
			default: IrVerifier.sameType(input, I64) && scalar(output);
		};
		return false;
	}
}
