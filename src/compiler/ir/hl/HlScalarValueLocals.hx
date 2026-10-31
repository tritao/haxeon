package compiler.ir.hl;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrOperands;
typedef HlScalarValueLocal = {final fields:Map<String, Int>; final declarations:Array<IrObjectField>;}

/** Frame-owned scalar slots for nonescaping value places, including across exception handlers. */
class HlScalarValueLocals {
	final candidates:Map<Int, HlScalarValueLocal> = [];

	public function new(fn:IrFunction, objects:Map<String, IrObject>, allocate:IrType->Int) {
		var roots:Map<Int, String> = [], valid:Map<Int, Bool> = [];
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case NewObject(out, name) if (objects.exists(name) && scalarFields(objects.get(name), objects)):
				roots.set(out.id, name); valid.set(out.id, true);
			default:
		}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				switch located.value {
					case Phi(_, inputs): for (input in inputs) if (roots.exists(input.value.id)) valid.set(input.value.id, false);
					default:
				}
				for (input in IrOperands.inputs(located.value)) if (roots.exists(input.id)) {
					var allowed = switch located.value {
						case FieldGet(_, owner, field) if (owner.id == input.id): hasField(objects.get(roots.get(input.id)), field);
						case FieldSet(owner, field, value) if (owner.id == input.id && value.id != input.id): hasField(objects.get(roots.get(input.id)), field);
						default: false;
					};
					if (!allowed) valid.set(input.id, false);
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _) if (roots.exists(value.id)): valid.set(value.id, false);
				default:
			}
		}
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case NewObject(out, name) if (roots.exists(out.id) && valid.get(out.id) == true):
				var fields:Map<String, Int> = [], declaration:IrObject = cast objects.get(name), declarations = declaration.fields;
				for (field in declarations) fields.set(field.name, allocate(field.type));
				candidates.set(out.id, {fields: fields, declarations: declarations});
			default:
		}
	}
	static function hasField(object:IrObject, name:String):Bool {
		for (field in object.fields) if (field.name == name) return true;
		return false;
	}
	static function scalarFields(object:IrObject, objects:Map<String, IrObject>):Bool {
		if (!object.isValue) return false;
		for (field in object.fields) {
			if (field.nativeLayout != null) return false;
			switch field.type {
				case Obj(name) if (objects.exists(name) && objects.get(name).isValue): return false;
				case Nullable(Obj(name)) if (objects.exists(name) && objects.get(name).isValue): return false;
				default:
			}
		}
		return true;
	}
	public function get(value:IrValue):Null<HlScalarValueLocal> return candidates.get(value.id);
}
