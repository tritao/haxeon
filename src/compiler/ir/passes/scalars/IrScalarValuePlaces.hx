package compiler.ir.passes.scalars;

import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFieldStorage;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrTypeTools;
import compiler.ir.model.IrValueId;

/**
 * The value places of one function body that never escape: a value construction whose object is read and written only through
 * its own fields, never passed on, joined, returned or thrown, and whose fields all keep their representation in a register.
 * Such a place can live as one local per field. HashLink lowering keeps them in registers (`HlScalarValueLocals`), and
 * `IrScalarArguments` asks the same question to decide whether a specialized callee keeps its value arguments in registers.
 *
 * Every read of an object type goes through `object`, so a caller that records what it reads (`HlLoweringView`) sees each one.
 */
class IrScalarValuePlaces {
	final valid:Map<Int, Bool> = [];

	public function new(body:IrBody, object:String->Null<IrObject>) {
		var roots:Map<Int, String> = [];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.ValueInit) {
					var out = body.output(row), name = IrTypeTools.valueObjectName(body.valueType(out));
					if (object(name) != null && scalarFields(object(name), object)) {
						roots.set(out, name);
						valid.set(out, true);
					}
				}
				row = body.nextRow(row);
			}
		}
		// A place may only be the object of a field read, or of a write of another value; any other use lets it escape.
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				for (index in 0...body.operandCount(row)) {
					var input = body.operand(row, index);
					if (roots.exists(input)) {
						var allowed = switch body.opcode(row) {
							case IrOpcode.FieldGet: index == 0
								&& hasField(object(roots.get(input)), body.symbol(row).name);
							case IrOpcode.FieldSet: index == 0 && (body.operand(row, 1):Int) != (input:Int)
								&& hasField(object(roots.get(input)), body.symbol(row).name);
							default: false;
						};
						if (!allowed)
							valid.set(input, false);
					}
				}
				row = body.nextRow(row);
			}
		}
	}

	/** Whether `value` is one of the places. */
	public function contains(value:IrValueId):Bool
		return valid.get(value) == true;

	static function hasField(object:IrObject, name:String):Bool {
		for (field in object.fields)
			if (field.name == name)
				return true;
		return false;
	}

	/** Whether every field of `object`, a value class, keeps its representation in a register. */
	public static function scalarFields(object:IrObject, lookup:String->Null<IrObject>):Bool {
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
