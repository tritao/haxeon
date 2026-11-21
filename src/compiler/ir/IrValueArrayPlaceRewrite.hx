package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance.SourceOrigin;

private typedef ArrayPlace = {
	final array:IrValueId;
	final index:IrValueId;
	final path:Array<String>;
}

/** Lower element-place projections before rewriting the remaining value-copy array reads, on a body edited in place. */
class IrValueArrayPlaceRewrite {
	/** Locate frontend-marked mutable roots without treating ordinary element copies as live places. */
	/** `roots` of a function: for a pass run on its own (a test). */
	public static function roots(fn:IrFunction, element:IrType):Map<Int, Bool>
		return bodyRoots(IrValueArrayRows.standaloneBody(fn), element);

	public static function bodyRoots(body:IrBody, element:IrType):Map<Int, Bool> {
		var result:Map<Int, Bool> = [],
			raw:Map<Int, Bool> = [],
			arrayType = body.typeId(Array(element)),
			elementType = body.typeId(element);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (placeMarked(body, row))
					switch body.opcode(row) {
						case IrOpcode.ArrayGet if (IrValueArrayRows.typed(body, body.operand(row, 0), arrayType)
							&& IrValueArrayRows.typed(body, body.output(row), elementType)):
							result.set(body.output(row), true);
						case IrOpcode.Call if (rawPlaceRead(body, row, arrayType)):
							raw.set(body.output(row), true);
						default:
					}
				row = body.nextRow(row);
			}
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.SafeCast && raw.exists(body.operand(row, 0))
					&& IrValueArrayRows.typed(body, body.output(row), elementType))
					result.set(body.output(row), true);
				row = body.nextRow(row);
			}
		}
		return result;
	}

	static function placeMarked(body:IrBody, row:Int):Bool
		return switch body.provenance(row).origin {
			case CompilerGenerated(reason) if (reason == IrGenerator.ArrayValuePlaceReason): true;
			default: false;
		};

	static function rawPlaceRead(body:IrBody, row:Int, arrayType:Int):Bool
		return body.symbol(row).name == "__array_get_any" && body.operandCount(row) == 2
			&& IrValueArrayRows.typed(body, body.operand(row, 0), arrayType);

	/** `fn` rewritten on a copy: for a pass run on its own (a test). */
	public static function rewrite(fn:IrFunction, element:IrType, objects:IrObjectTable,
			helpers:IrValueArraySlotHelpers,
			methods:IrValueArrayPlaceMethods, roots:Map<Int, Bool>):IrFunction {
		var body = IrValueArrayRows.standaloneBody(fn);
		rewriteBody(body, element, objects, helpers, methods, roots);
		return body.toFunction();
	}

	/** Rewrites `body` in place; it always changes. */
	public static function rewriteBody(body:IrBody, element:IrType, objects:IrObjectTable,
			helpers:IrValueArraySlotHelpers,
			methods:IrValueArrayPlaceMethods, roots:Map<Int, Bool>):Void {
		var arrayType = body.typeId(Array(element)),
			elementType = body.typeId(element),
			dynType = body.typeId(Dyn),
			voidType = body.typeId(Void),
			boolType = body.typeId(Bool),
			aliases:Map<Int, ArrayPlace> = [],
			raw:Map<Int, ArrayPlace> = [],
			nulls:Map<Int, Bool> = [];
		function requiredPlace(id:Int):ArrayPlace {
			var place = aliases.get(id);
			if (place == null)
				throw new InternalError('Missing array place $id');
			return place;
		}
		function isValue(value:IrValueId):Bool
			return switch body.valueType(value) {
				case Obj(name), Nullable(Obj(name)): var object = objects.get(name);
					object != null && object.isValue;
				default: false;
			};
		function isNullableScalar(value:IrValueId):Bool
			return switch body.valueType(value) {
				case Nullable(I32 | I64 | F32 | F64 | Bool): true;
				default: false;
			};
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var out = body.output(row);
				switch body.opcode(row) {
					case IrOpcode.ConstNull:
						nulls.set(out, true);
					case IrOpcode.ArrayGet if (roots.exists(out)):
						if (!IrValueArrayRows.typed(body, body.operand(row, 0), arrayType)
							|| !IrValueArrayRows.typed(body, out, elementType))
							throw new InternalError("Invalid array place root");
						aliases.set(out, {array: body.operand(row, 0), index: body.operand(row, 1), path: []});
					case IrOpcode.Call if (rawPlaceRead(body, row, arrayType) && placeMarked(body, row)):
						raw.set(out, {array: body.operand(row, 0), index: body.operand(row, 1), path: []});
					default:
				}
				row = body.nextRow(row);
			}
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.SafeCast && roots.exists(body.output(row))
					&& raw.exists(body.operand(row, 0))) {
					var place = raw.get(body.operand(row, 0));
					if (place == null)
						throw new InternalError("Missing checked array place");
					aliases.set(body.output(row), place);
				}
				row = body.nextRow(row);
			}
		}
		for (id in roots.keys())
			if (!aliases.exists(id))
				throw new InternalError('Missing array place root $id');
		var changed = true;
		while (changed) {
			changed = false;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					var out = body.output(row);
					switch body.opcode(row) {
						case IrOpcode.FieldGet if (aliases.exists(body.operand(row, 0)) && isValue(out)
							&& !aliases.exists(out)):
							var parent = requiredPlace(body.operand(row, 0));
							aliases.set(out, {
								array: parent.array,
								index: parent.index,
								path: parent.path.concat([body.symbol(row).name])
							});
							changed = true;
						case IrOpcode.SafeCast if (aliases.exists(body.operand(row, 0)) && isValue(out)
							&& !aliases.exists(out)):
							aliases.set(out, requiredPlace(body.operand(row, 0)));
							changed = true;
						case IrOpcode.ToDyn if (aliases.exists(body.operand(row, 0))
							&& (IrValueArrayRows.typed(body, out, elementType)
							|| IrValueArrayRows.typed(body, out, dynType))
							&& !aliases.exists(out)):
							aliases.set(out, requiredPlace(body.operand(row, 0)));
							changed = true;
						default:
					}
					row = body.nextRow(row);
				}
			}
		}
		/** Replaces `row` by a check of the place's path (with the element itself when `includeSelf`). */
		function checkInstead(block:Int, row:Int, place:ArrayPlace):Void {
			var check = body.newValue("$array-place-check", voidType);
			IrValueArrayRows.call2(body, block, row, check, helpers.checker(place.path, true), place.array, place.index,
				body.provenance(row));
			body.removeRow(block, row);
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var following = body.nextRow(row),
					out = body.output(row),
					where = body.provenance(row),
					handled = true;
				switch body.opcode(row) {
					case IrOpcode.Call if (body.symbol(row).name == "__array_get_any" && raw.exists(out)):
						var place = raw.get(out);
						if (place == null)
							throw new InternalError("Missing checked array place");
						checkInstead(block, row, place);
					case IrOpcode.ArrayGet if (roots.exists(out)):
						checkInstead(block, row, requiredPlace(out));
					case IrOpcode.FieldGet if (aliases.exists(body.operand(row, 0))):
						var place = requiredPlace(body.operand(row, 0)),
							path = place.path.concat([body.symbol(row).name]),
							check = body.newValue("$array-place-check", voidType);
						IrValueArrayRows.call2(body, block, row, check, helpers.checker(path, false), place.array,
							place.index,
							where);
						if (!isValue(out)) {
							var getter = isNullableScalar(out) ? methods.scalarGetter(body.valueType(out),
								path) : helpers.getter(helpers.slot(path));
							IrValueArrayRows.call2(body, block, row, out, getter, place.array, place.index, where);
						}
						body.removeRow(block, row);
					case IrOpcode.FieldSet if (aliases.exists(body.operand(row, 0))):
						var place = requiredPlace(body.operand(row, 0)),
							value = body.operand(row, 1),
							path = place.path.concat([body.symbol(row).name]),
							check = body.newValue("$array-place-check", voidType);
						if (aliases.exists(value))
							throw new InternalError("Aliased place write requires component specialization");
						IrValueArrayRows.call2(body, block, row, check, helpers.checker(path, false), place.array,
							place.index,
							where);
						var setter = isValue(value)
							|| isNullableScalar(value) ? methods.valueSetter(body.valueType(value),
							path) : helpers.setter(helpers.slot(path));
						IrValueArrayRows.call3(body, block, row, body.newValue("$array-place-write", voidType), setter,
							place.array,
							place.index, value, where);
						body.removeRow(block, row);
					case IrOpcode.SafeCast if (roots.exists(out) && raw.exists(body.operand(row, 0))):
						body.removeRow(block, row);
					case IrOpcode.ToDyn if (aliases.exists(body.operand(row, 0)) && aliases.exists(out)):
						body.removeRow(block, row);
					case IrOpcode.Equal if ((aliases.exists(body.operand(row, 0)) && nulls.exists(body.operand(row, 1)))
						|| (aliases.exists(body.operand(row, 1)) && nulls.exists(body.operand(row, 0)))):
						var place = requiredPlace(aliases.exists(body.operand(row, 0)) ? body.operand(row,
							0) : body.operand(row,
							1)),
							present = body.newValue("$array-place-present", boolType),
							no = body.newValue("$array-place-false", boolType);
						IrValueArrayRows.call2(body, block, row, present,
							helpers.getter(helpers.slot(place.path, true)),
							place.array, place.index, where);
						IrValueArrayRows.constBool(body, block, row, no, false, where);
						body.setOperand(row, 0, present);
						body.setOperand(row, 1, no);
					case IrOpcode.SafeCast if (aliases.exists(body.operand(row, 0)) && aliases.exists(out)):
						checkInstead(block, row, requiredPlace(body.operand(row, 0)));
					case IrOpcode.MethodCall if (aliases.exists(body.operand(row, 0))):
						for (index in 1...body.operandCount(row))
							if (aliases.exists(body.operand(row, index)))
								throw new InternalError("Array place argument requires component specialization");
						var owner = body.operand(row, 0),
							place = requiredPlace(owner),
							name = methods.method(body.valueType(owner), body.symbol(row).name, place.path);
						body.beginRow();
						body.pushOperand(place.array);
						body.pushOperand(place.index);
						for (index in 1...body.operandCount(row))
							body.pushOperand(body.operand(row, index));
						IrValueArrayRows.linkCall(body, block, row, out, name, where);
						body.removeRow(block, row);
					case IrOpcode.ArraySet if (aliases.exists(body.operand(row, 2))):
						var place = requiredPlace(body.operand(row, 2));
						if (place.path.length != 0 || place.array != body.operand(row, 0)
							|| place.index != body.operand(row, 1))
							throw new InternalError("Array place writeback changed its destination");
						body.removeRow(block, row);
					case IrOpcode.Call if (body.symbol(row).name == "__array_set_any" && body.operandCount(row) == 3
						&& aliases.exists(body.operand(row, 2))):
						var place = requiredPlace(body.operand(row, 2));
						if (place.path.length != 0 || place.array != body.operand(row, 0)
							|| place.index != body.operand(row, 1))
							throw new InternalError("Checked array place writeback changed its destination");
						body.removeRow(block, row);
					default:
						handled = false;
				}
				if (!handled)
					for (index in 0...body.operandCount(row))
						if (aliases.exists(body.operand(row, index)))
							throw new InternalError(body.opcode(row) == IrOpcode.Phi
								? "Array place phi requires component specialization" : body.opcode(row)
								.isTerminator() ? "Array place escapes through a terminator"
								: 'Array place ${body.operand(row, index)} escapes through row $row of ${body.name}');
				row = following;
			}
		}
		IrValueArrayRows.removeBindings(body, value -> aliases.exists(value));
	}
}
