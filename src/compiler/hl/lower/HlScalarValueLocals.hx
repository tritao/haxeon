package compiler.hl.lower;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrScalarValuePlaces;

typedef HlScalarValueLocal = {
	final fields:Map<String, Int>;
	final declarations:Array<IrObjectField>;
}

/** Frame-owned scalar slots for nonescaping value places (`IrScalarValuePlaces`), including across exception handlers. */
class HlScalarValueLocals {
	final candidates:Map<Int, HlScalarValueLocal> = [];

	public function new(fn:IrFunction, objects:HlLoweringView, allocate:IrType->Int) {
		for (out in new IrScalarValuePlaces(fn, objects.object).places) {
			var fields:Map<String, Int> = [],
				declaration:IrObject = cast objects.object(compiler.ir.IrTypeTools.valueObjectName(out.type)),
				declarations = declaration.fields;
			for (field in declarations)
				fields.set(field.name, allocate(field.type));
			candidates.set(out.id, {fields: fields, declarations: declarations});
		}
	}

	public function get(value:IrValue):Null<HlScalarValueLocal>
		return candidates.get(value.id);
}
