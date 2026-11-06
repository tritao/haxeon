package compiler.ir;

import compiler.ir.Ir.IrType;

/** Internal bit transport for unmanaged pointers, type IDs, and Wasm callback handles. */
class IrScalarWordBits {
	public static inline final PACK = "$word:scalar-pack";
	public static inline final UNPACK = "$word:scalar-unpack";

	public static function matches(name:String):Bool return name == PACK || name == UNPACK;

	public static function scalar(type:IrType):Bool return switch type {
		case RawPtr, TypeRef, Abstract("native_callback"): true;
		default: false;
	};

	public static function valid(name:String, input:IrType, output:IrType):Bool
		return name == PACK ? scalar(input) && IrVerifier.sameType(output, I64)
			: name == UNPACK && IrVerifier.sameType(input, I64) && scalar(output);
}
