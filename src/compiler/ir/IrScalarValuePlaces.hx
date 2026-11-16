package compiler.ir;

import compiler.ir.Ir;

/**
 * The value places of one function that never escape: a value construction whose object is read and written only through
 * its own fields, never passed on, joined, returned or thrown, and whose fields all keep their representation in a register.
 * Such a place can live as one local per field. HashLink lowering keeps them in registers (`HlScalarValueLocals`), and
 * `IrScalarArguments` asks the same question to decide whether a specialized callee keeps its value arguments in registers.
 *
 * Every read of an object type goes through `object`, so a caller that records what it reads (`HlLoweringView`) sees each one.
 */
class IrScalarValuePlaces {
	final valid:Map<Int, Bool> = [];

	/** The constructions that qualify, in instruction order. */
	public final places:Array<IrValue> = [];

	public function new(fn:IrFunction, object:String->Null<IrObject>) {
		var roots:Map<Int, String> = [];
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case ValueInit(out)
						if (object(IrTypeTools.valueObjectName(out.type)) != null
						&& scalarFields(object(IrTypeTools.valueObjectName(out.type)), object)):
						var name = IrTypeTools.valueObjectName(out.type);
						roots.set(out.id, name);
						valid.set(out.id, true);
					default:
				}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				switch located.value {
					case Phi(_, inputs):
						for (input in inputs)
							if (roots.exists(input.value.id))
								valid.set(input.value.id, false);
					default:
				}
				for (inputIndex in 0...IrOperands.count(located.value)) {
					var input = IrOperands.at(located.value, inputIndex);
					if (roots.exists(input.id)) {
						var allowed = switch located.value {
							case FieldGet(_, owner,
								field) if (owner.id == input.id): hasField(object(roots.get(input.id)), field);
							case FieldSet(owner, field,
								value) if (owner.id == input.id
								&& value.id != input.id): hasField(object(roots.get(input.id)),
								field);
							default: false;
						};
						if (!allowed)
							valid.set(input.id, false);
					}
				}
			}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _) if (roots.exists(value.id)):
						valid.set(value.id, false);
					default:
				}
		}
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case ValueInit(out) if (roots.exists(out.id) && valid.get(out.id) == true):
						places.push(out);
					default:
				}
	}

	/** Whether `value` is one of the places. */
	public function contains(value:IrValue):Bool
		return valid.get(value.id) == true;

	static function hasField(object:IrObject, name:String):Bool {
		for (field in object.fields)
			if (field.name == name)
				return true;
		return false;
	}

	static function scalarFields(object:IrObject, lookup:String->Null<IrObject>):Bool {
		if (!object.isValue)
			return false;
		for (field in object.fields) {
			// Native storage is scalar-safe only when the register has the same representation as the field.
			// Narrow integer fields still need truncation and sign extension on every store/load.
			if (field.nativeLayout != null && field.nativeLayout.inlineRecord)
				return false;
			var native = IrFieldStorage.scalar(field);
			if (native != null) {
				var exact = switch field.type {
					case I32: native.size == 4;
					case I64: native.size == 8;
					case F32: native.size == 4;
					case F64: native.size == 8;
					case Bool: native.size == 1;
					default: false;
				};
				if (!exact)
					return false;
			}
			switch field.type {
				case Obj(name), Nullable(Obj(name)):
					var object = lookup(name);
					if (object != null && object.isValue)
						return false;
				default:
			}
		}
		return true;
	}
}
