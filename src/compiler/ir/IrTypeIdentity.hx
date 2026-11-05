package compiler.ir;

import compiler.ir.Ir.IrType;

/** Stable runtime discriminator for an IR type. Exact type checks resolve collisions. */
class IrTypeIdentity {
	public static function id(type:IrType):Int {
		var text = Std.string(type), hash:Int = -2128831035;
		for (index in 0...text.length) {
			hash = Std.int(hash ^ text.charCodeAt(index));
			hash = Std.int(hash * 16777619);
		}
		return hash;
	}
}
