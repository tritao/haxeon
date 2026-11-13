package compiler.backend.wasm;

import compiler.backend.wasm.WasmFlattenValueFields;
import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrOperands;
import compiler.backend.wasm.WasmTypes.WasmValueType;

typedef WasmScalarLocal = {final typeName:String; final fields:Map<String, Int>; final declarations:Array<IrObjectField>;}

/** Mutable Wasm locals for value objects used only as field places, including across exception handlers. */
class WasmScalarLocals {
	final candidates:Map<Int, WasmScalarLocal> = [];

	public function new(fn:Null<IrFunction>, isValue:IrType->Bool, physicalFields:String->Array<IrObjectField>, valueType:IrType->WasmValueType,
			allocate:WasmValueType->Int) {
		if (fn == null)
			return;
		var roots:Map<Int, String> = [], valid:Map<Int, Bool> = [];
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case ValueInit(out) if (isValue(out.type)):
						var name = compiler.ir.IrTypeTools.valueObjectName(out.type);
						roots.set(out.id, name);
						valid.set(out.id, true);
					default:
				}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				var instruction = located.value;
				switch instruction {
					case Phi(_, inputs):
						for (input in inputs)
							if (roots.exists(input.value.id))
								valid.set(input.value.id, false);
					default:
				}
				for (input in IrOperands.inputs(instruction))
					if (roots.exists(input.id)) {
						var allowed = switch instruction {
							case FieldGet(_, owner, name) if (owner.id == input.id): name == WasmFlattenValueFields.CHECK_FIELD || hasField(physicalFields(roots.get(input.id)),
									name);
							case FieldSet(owner, name, value) if (owner.id == input.id && value.id != input.id):
								hasField(physicalFields(roots.get(input.id)), name);
							default: false;
						};
						if (!allowed)
							valid.set(input.id, false);
					}
			}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _) if (roots.exists(value.id)):
						valid.set(value.id, false);
					default:
				}
		}
		// Allocate in source order, not map iteration order, for deterministic output.
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case ValueInit(out) if (roots.exists(out.id) && valid.get(out.id) == true):
						var name = compiler.ir.IrTypeTools.valueObjectName(out.type);
						var fields:Map<String, Int> = [],
							declarations = physicalFields(name);
						for (field in declarations)
							fields.set(field.name, allocate(valueType(field.type)));
						candidates.set(out.id, {typeName: name, fields: fields, declarations: declarations});
					default:
				}
	}

	static function hasField(fields:Array<IrObjectField>, name:String):Bool {
		for (field in fields)
			if (field.name == name)
				return true;
		return false;
	}

	public function get(value:IrValue):Null<WasmScalarLocal>
		return candidates.get(value.id);

	public function all():Map<Int, WasmScalarLocal>
		return candidates;
}
