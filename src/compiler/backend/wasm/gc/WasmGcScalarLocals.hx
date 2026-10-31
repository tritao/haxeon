package compiler.backend.wasm.gc;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrOperands;
import compiler.backend.wasm.WasmTypes.WasmValueType;

typedef WasmGcScalarLocal = {final typeName:String; final fields:Map<String, Int>; final declarations:Array<IrObjectField>;}

/** Mutable Wasm locals for value objects used only as field places, including across exception handlers. */
class WasmGcScalarLocals {
	final candidates:Map<Int, WasmGcScalarLocal> = [];

	public function new(plan:WasmGcTypePlan, fn:Null<IrFunction>, allocate:WasmValueType->Int) {
		if (fn == null || !plan.inlineValueFields) return;
		var roots:Map<Int, String> = [], valid:Map<Int, Bool> = [];
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case NewObject(out, name) if (plan.values.isValue(out.type)):
				roots.set(out.id, name); valid.set(out.id, true);
			default:
		}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				var instruction = located.value;
				switch instruction {
					case Phi(_, inputs): for (input in inputs) if (roots.exists(input.value.id)) valid.set(input.value.id, false);
					default:
				}
				for (input in IrOperands.inputs(instruction)) if (roots.exists(input.id)) {
					var allowed = switch instruction {
						case FieldGet(_, owner, name) if (owner.id == input.id):
							name == WasmGcFlattenFields.CHECK_FIELD || plan.hasPhysicalField(roots.get(input.id), name);
						case FieldSet(owner, name, value) if (owner.id == input.id && value.id != input.id):
							plan.hasPhysicalField(roots.get(input.id), name);
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
		// Allocate in source order, not map iteration order, for deterministic output.
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case NewObject(out, name) if (roots.exists(out.id) && valid.get(out.id) == true):
				var fields:Map<String, Int> = [], declarations = plan.physicalFields(name);
				for (field in declarations) fields.set(field.name, allocate(plan.valueType(field.type)));
				candidates.set(out.id, {typeName: name, fields: fields, declarations: declarations});
			default:
		}
	}

	public function get(value:IrValue):Null<WasmGcScalarLocal> return candidates.get(value.id);
}
