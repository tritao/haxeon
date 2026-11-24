package compiler.ir.model;

import compiler.ir.model.Ir.IrObjectField;
import compiler.ir.model.Ir.IrScalarStorage;

/** Scalar width applies to managed fields as well as fields with an enclosing C layout. */
@:nullSafety(Strict)
class IrFieldStorage {
	public static function scalar(field:IrObjectField):Null<IrScalarStorage> {
		if (field.scalarStorage != null) return field.scalarStorage;
		var native = field.nativeLayout;
		return native == null || native.inlineRecord ? null : {size: native.size, signed: native.signed};
	}
}
