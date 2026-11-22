package compiler.ir.passes.arrays;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrValueId;
import compiler.ir.passes.objects.IrCheckedDynamicCasts;
import compiler.ir.passes.values.IrValueInterfaceBoxes;
import compiler.ir.verify.IrVerifier;

/** Lower plain array element reads and writes after element-place operations have been separated, on a body edited in place. */
@:nullSafety(Strict)
class IrValueArrayElementRewrite {
	/** `fn` rewritten on a copy, or `fn` when nothing changes: for a pass run on its own (a test). */
	public static function rewrite(fn:IrFunction, element:IrType, helpers:IrValueArrayElements,
			tagUnboxes:Map<String, IrType>):IrFunction {
		var body = IrValueArrayRows.standaloneBody(fn);
		return rewriteBody(body, element, helpers, tagUnboxes, []) ? body.toFunction() : fn;
	}

	/** Whether `body` changed; `uses` is a table this reuses. */
	public static function rewriteBody(body:IrBody, element:IrType, helpers:IrValueArrayElements,
			tagUnboxes:Map<String, IrType>, uses:Array<Int>):Bool {
		var changed = rewriteCheckedSplice(body, element, helpers, tagUnboxes, uses);
		var arrayType = body.typeId(Array(element)),
			iteratorType = body.typeId(Iterator(element)),
			storage = body.typeId(helpers.storage),
			i32 = body.typeId(I32),
			voidType = body.typeId(Void);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var following = body.nextRow(row), out = body.output(row);
				switch body.opcode(row) {
					case IrOpcode.IteratorNew if (IrValueArrayRows.typed(body, body.operand(row, 0), arrayType)):
						helpers.useIterator();
						IrValueArrayRows.replaceByCall(body, block, row, out, helpers.iteratorNewName());
						changed = true;
					case IrOpcode.IteratorNext if (IrValueArrayRows.typed(body, body.operand(row, 0), iteratorType)):
						if (!IrValueArrayRows.typed(body, out, storage))
							throw new InternalError('Wrong inline array iterator type ${body.valueType(out)}');
						helpers.useIterator();
						IrValueArrayRows.replaceByCall(body, block, row, out, helpers.iteratorNextName());
						changed = true;
					case IrOpcode.ArrayGet if (IrValueArrayRows.typed(body, body.operand(row, 0), arrayType)):
						if (!IrValueArrayRows.typed(body, out, storage))
							throw new InternalError('Wrong inline array read type ${body.valueType(out)}');
						IrValueArrayRows.replaceByCall(body, block, row, out, helpers.getName());
						changed = true;
					case IrOpcode.ArraySet if (IrValueArrayRows.typed(body, body.operand(row, 0), arrayType)):
						if (!IrValueArrayRows.typed(body, body.operand(row, 2), storage))
							throw new InternalError('Wrong inline array write type ${body.valueType(body.operand(row, 2))}');
						IrValueArrayRows.replaceByCall(body, block, row,
							body.newValue("$array-element-write", voidType),
							helpers.setName());
						changed = true;
					case IrOpcode.Call if (body.operandCount(row) > 0
						&& IrValueArrayRows.typed(body, body.operand(row, 0), arrayType)):
						var name = rename(body, row, element, helpers, storage, i32, voidType, arrayType);
						if (name != null) {
							body.setAux(row, IrSymbol.of(name).id);
							changed = true;
						}
					default:
				}
				row = following;
			}
		}
		return changed;
	}

	/** The element helper or native array call `row` (on a value array) becomes, or null when it stays. */
	static function rename(body:IrBody, row:Int, element:IrType, helpers:IrValueArrayElements, storage:Int, i32:Int,
			voidType:Int, arrayType:Int):Null<String> {
		var count = body.operandCount(row), out = body.output(row);
		inline function typed(value:IrValueId, type:Int):Bool
			return IrValueArrayRows.typed(body, value, type);
		return switch body.symbol(row).name {
			case "__array_push_ref" if (count == 2):
				if (!typed(body.operand(row, 1), storage) || !typed(out, i32))
					throw new InternalError("Wrong inline array push type");
				helpers.pushName();
			case "__array_unshift_ref" if (count == 2):
				if (!typed(body.operand(row, 1), storage) || !typed(out, i32))
					throw new InternalError("Wrong inline array unshift type");
				helpers.unshiftName();
			case "__array_pop_ref" if (count == 1 && typed(out, storage)): helpers.popName();
			case "__array_shift_ref" if (count == 1 && typed(out, storage)): helpers.shiftName();
			case "__array_insert_ref" if (count == 3):
				if (!typed(body.operand(row, 2), storage) || !typed(body.operand(row, 1), i32) || !typed(out, voidType))
					throw new InternalError("Wrong inline array insert type");
				helpers.insertName();
			case "__array_resize_ref" | "__array_resize_any" if (count == 2):
				if (!typed(body.operand(row, 1), i32) || !typed(out, voidType))
					throw new InternalError("Wrong inline array resize type");
				"__value_array_resize";
			case "__array_reverse_ref" | "__array_reverse_any" if (count == 1):
				if (!typed(out, voidType))
					throw new InternalError("Wrong inline array reverse type");
				"__value_array_reverse";
			case "__array_splice_ref" if (count == 3):
				if (!typed(body.operand(row, 1), i32) || !typed(body.operand(row, 2), i32) || !typed(out, arrayType))
					throw new InternalError("Wrong inline array splice type");
				IrValueArrayElements.spliceNativeName(element);
			default: null;
		};
	}

	/** Checked removals and splices: a dynamic result converted back at once becomes the element helper's typed result. */
	static function rewriteCheckedSplice(body:IrBody, element:IrType, helpers:IrValueArrayElements,
			tagUnboxes:Map<String, IrType>, uses:Array<Int>):Bool {
		var arrayType = body.typeId(Array(element)),
			storage = body.typeId(helpers.storage),
			dynType = body.typeId(Dyn),
			i32 = body.typeId(I32),
			counted = false,
			removed:Null<Map<Int, Bool>> = null;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var following = body.nextRow(row);
				if (body.opcode(row) == IrOpcode.Call && body.operandCount(row) > 0
					&& IrValueArrayRows.typed(body, body.operand(row, 0), arrayType)) {
					var name = body.symbol(row).name, raw = body.output(row);
					if ((name == "__array_pop_ref" || name == "__array_shift_ref") && body.operandCount(row) == 1
						&& IrValueArrayRows.typed(body, raw, dynType)) {
						var conversion = IrValueArrayRows.nextInstruction(body, row);
						if (conversion < 0)
							throw new InternalError("Missing checked value array removal conversion");
						if (!counted) {
							IrValueArrayRows.countUses(body, uses);
							counted = true;
						}
						var out = body.output(conversion);
						var matches = body.operandCount(conversion) == 1 && body.operand(conversion, 0) == raw
							&& IrValueArrayRows.typed(body, out, storage) && uses[raw] == 1
							&& switch body.opcode(conversion) {
								case IrOpcode.SafeCast: true;
								case IrOpcode.Call:
									var converter = body.symbol(conversion).name, unboxed = tagUnboxes.get(converter);
									StringTools.startsWith(converter, IrCheckedDynamicCasts.PREFIX)
										|| StringTools.startsWith(converter, IrValueInterfaceBoxes.UNBOX_PREFIX)
										|| (unboxed != null && IrVerifier.sameType(element, unboxed));
								default: false;
							};
						if (!matches)
							throw new InternalError('Invalid checked value array removal conversion in ${body.name}: row $conversion');
						following = body.nextRow(conversion);
						body.removeRow(block, conversion);
						IrValueArrayRows.replaceByCall(body, block, row, out,
							name == "__array_pop_ref" ? helpers.popName() : helpers.shiftName());
						if (removed == null)
							removed = [];
						removed.set(raw, true);
					} else if (name == "__array_splice_any" && body.operandCount(row) == 3) {
						var boxing = IrValueArrayRows.nextInstruction(body, row),
							castRow = boxing < 0 ? -1 : IrValueArrayRows.nextInstruction(body, boxing);
						if (castRow < 0)
							throw new InternalError("Missing checked nullable array splice conversion");
						if (!counted) {
							IrValueArrayRows.countUses(body, uses);
							counted = true;
						}
						var boxed = body.output(boxing), out = body.output(castRow);
						if (body.opcode(boxing) != IrOpcode.ToDyn || body.opcode(castRow) != IrOpcode.SafeCast
							|| body.operand(boxing, 0) != raw || body.operand(castRow, 0) != boxed
							|| !IrValueArrayRows.typed(body, out, arrayType)
							|| !IrValueArrayRows.typed(body, body.operand(row, 1), i32)
							|| !IrValueArrayRows.typed(body, body.operand(row, 2), i32) || uses[raw] != 1
							|| uses[boxed] != 1)
							throw new InternalError("Invalid checked nullable array splice conversion");
						following = body.nextRow(castRow);
						body.removeRow(block, castRow);
						body.removeRow(block, boxing);
						IrValueArrayRows.replaceByCall(body, block, row, out,
							IrValueArrayElements.spliceNativeName(element));
						if (removed == null)
							removed = [];
						removed.set(raw, true);
						removed.set(boxed, true);
					}
				}
				row = following;
			}
		}
		if (removed == null)
			return false;
		IrValueArrayRows.removeBindings(body, value -> removed.exists(value));
		return true;
	}
}
