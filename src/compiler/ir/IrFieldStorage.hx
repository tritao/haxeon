package compiler.ir;

import compiler.ir.Ir.IrObjectField;
import compiler.ir.Ir.IrScalarStorage;

/** Scalar width applies to managed fields as well as fields with an enclosing C layout. */
class IrFieldStorage {
	public static function scalar(field:IrObjectField):Null<IrScalarStorage> {
		if (field.scalarStorage != null) return field.scalarStorage;
		var native = field.nativeLayout;
		return native == null || native.inlineRecord ? null : {size: native.size, signed: native.signed};
	}
}
