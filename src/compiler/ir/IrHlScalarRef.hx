package compiler.ir;

import compiler.ir.Ir.IrType;
import compiler.ir.codec.IrTypeCodec;

/** Compiler-internal, nonescaping reference to a scalar in a live HashLink stack frame. */
class IrHlScalarRef {
	static inline final TYPE_PREFIX = "$hl:scalar-ref:";
	public static inline final ADDRESS = "$hl:scalar-address";
	public static inline final LOAD = "$hl:scalar-load";
	public static inline final STORE = "$hl:scalar-store";
	public static inline final CHECK_RECEIVER = "$hl:scalar-check-receiver";

	public static function type(value:IrType):IrType
		return Abstract(TYPE_PREFIX + haxe.crypto.Base64.encode(IrTypeCodec.encode(value)));

	public static function element(type:IrType):Null<IrType>
		return switch type {
			case Abstract(name) if (StringTools.startsWith(name, TYPE_PREFIX)):
				IrTypeCodec.decode(haxe.crypto.Base64.decode(name.substr(TYPE_PREFIX.length)));
			default: null;
		};
}
