package compiler.backend.wasm.gc;

import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrObjectField;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrInlineValueLayout;
import compiler.ir.IrInlineValueLayout.IrInlineValueSlot;
import compiler.ir.IrObjectTable;

/** The scalar storage shape shared by Wasm GC fields and value calling conventions. */
class WasmGcValueLayout {
	final objects:Map<String, IrObject>;
	final layout:IrInlineValueLayout;

	public function new(program:IrProgram) {
		objects = [for (object in program.objects) object.name => object];
		layout = new IrInlineValueLayout(IrObjectTable.of(objects));
	}

	/** Optional values retain their existing reference representation at value boundaries. */
	public function isValue(type:IrType):Bool
		return switch type {
			case Obj(name):
				var object = objects.get(name);
				object != null && object.isValue;
			default: false;
		};

	/** Leaves are in declaration order and contain the complete path from the value root. */
	public function leaves(type:IrType):Array<IrInlineValueSlot> {
		if (!isValue(type)) throw 'Not a Wasm GC value type: $type';
		return layout.slots(type);
	}

	/** Physical field declarations preserve inherited prefixes and source declaration order. */
	public function fields(logical:Array<IrObjectField>):Array<IrObjectField> {
		var result:Array<IrObjectField> = [];
		for (field in logical) {
			if (!isValue(field.type)) result.push(field);
			else for (slot in leaves(field.type)) result.push({
				name: IrInlineValueLayout.slotName(field.name, slot),
				type: slot.type,
				nativeLayout: slot.nativeLayout
			});
		}
		return result;
	}

	public static function fieldName(field:String, slot:IrInlineValueSlot):String
		return IrInlineValueLayout.slotName(field, slot);
}
