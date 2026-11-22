package compiler.ir.passes.arrays;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrValueId;
import compiler.ir.passes.nullability.IrOptionalValueFlow;

private typedef OptionalArrayAccess = {
	final block:Int;
	final position:Int;
	final array:IrValueId;
	final index:IrValueId;
	final operation:String;
}

private typedef OptionalBox = {
	final block:Int;
	final position:Int;
	final wrapper:IrValueId;
}

/** Keep optional-scalar wrappers in components when they cross a typed array boundary, on a body edited in place. */
class IrValueArrayOptionalRewrite {
	/** Whether `body` changed; `uses` is a table this reuses. Positions are rows' places in their blocks, blocks their indices. */
	/** `fn` rewritten on a copy, or `fn` when nothing changes: for a pass run on its own (a test). */
	public static function rewrite(fn:IrFunction, element:IrType,
			components:IrValueArrayOptionalComponents):IrFunction {
		var body = IrValueArrayRows.standaloneBody(fn);
		return rewriteBody(body, element, components, []) ? body.toFunction() : fn;
	}

	public static function rewriteBody(body:IrBody, element:IrType, components:IrValueArrayOptionalComponents,
			uses:Array<Int>):Bool {
		var name = switch element {
			case Nullable(Obj(value)): value;
			default: throw new InternalError("Expected a nullable struct element");
		},
			arrayType = body.typeId(Array(element)),
			elementType = body.typeId(element),
			wrapperType = body.typeId(components.wrapperType()),
			dynType = body.typeId(Dyn),
			boxName = IrOptionalValueFlow.boxName(name),
			unboxName = IrOptionalValueFlow.unboxName(name),
			reads:Map<Int, OptionalArrayAccess> = [],
			boxes:Map<Int, OptionalBox> = [],
			unboxes:Map<Int, IrValueId> = [],
			writes:Map<Int, IrValueId> = [],
			anyReads:Map<Int, OptionalArrayAccess> = [],
			castSources:Map<Int, Int> = [],
			rawReads:Map<Int, Int> = [],
			dynamicValues:Map<Int, {
				boxed:Int,
				block:Int,
				position:Int
			}> = [],
			dynamicWrites:Map<Int, IrValueId> = [],
			dynamicBoxes:Map<Int, Bool> = [];
		IrValueArrayRows.countUses(body, uses);
		function readAt(id:Int):OptionalArrayAccess {
			var value = reads.get(id);
			if (value == null)
				throw new InternalError('Missing optional array read $id');
			return value;
		}
		function boxAt(id:Int):OptionalBox {
			var value = boxes.get(id);
			if (value == null)
				throw new InternalError('Missing optional array box $id');
			return value;
		}
		function unboxed(id:Int):IrValueId {
			var value = unboxes.get(id);
			if (value == null)
				throw new InternalError('Missing optional array unbox $id');
			return value;
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), position = 0;
			while (row >= 0) {
				var value = body.output(row);
				switch body.opcode(row) {
					case IrOpcode.ArrayGet if (IrValueArrayRows.typed(body, body.operand(row, 0), arrayType)
						&& IrValueArrayRows.typed(body, value, elementType)):
						reads.set(value, {
							block: block,
							position: position,
							array: body.operand(row, 0),
							index: body.operand(row, 1),
							operation: "get"
						});
					case IrOpcode.Call:
						var callee = body.symbol(row).name;
						if (callee == "__array_get_any" && body.operandCount(row) == 2
							&& IrValueArrayRows.typed(body, body.operand(row, 0), arrayType))
							anyReads.set(value, {
								block: block,
								position: position,
								array: body.operand(row, 0),
								index: body.operand(row, 1),
								operation: "get"
							});
						else if ((callee == "__array_pop_ref" || callee == "__array_shift_ref"
							|| callee == "__array_pop_any"
							|| callee == "__array_shift_any")
							&& body.operandCount(row) == 1
							&& IrValueArrayRows.typed(body, body.operand(row, 0), arrayType)) {
							var read:OptionalArrayAccess = {
								block: block,
								position: position,
								array: body.operand(row, 0),
								index: IrValueId.of(-1),
								operation: callee.indexOf("pop") >= 0 ? "pop" : "shift"
							};
							if (IrValueArrayRows.typed(body, value, elementType))
								reads.set(value, read);
							else
								anyReads.set(value, read);
						} else if (callee == boxName && body.operandCount(row) == 1
							&& IrValueArrayRows.typed(body, value, elementType)
							&& IrValueArrayRows.typed(body, body.operand(row, 0), wrapperType))
							boxes.set(value, {block: block, position: position, wrapper: body.operand(row, 0)});
					case IrOpcode.ToDyn if (IrValueArrayRows.typed(body, body.operand(row, 0), elementType)
						&& IrValueArrayRows.typed(body, value, dynType)):
						dynamicValues.set(value, {boxed: body.operand(row, 0), block: block, position: position});
					default:
				}
				row = body.nextRow(row);
				position++;
			}
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), position = 0;
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.SafeCast) {
					var out = body.output(row), value = body.operand(row, 0);
					if (IrValueArrayRows.typed(body, out, elementType) && anyReads.exists(value) && uses[value] == 1) {
						var read = anyReads.get(value);
						if (read.block == block && read.position < position) {
							reads.set(out, read);
							castSources.set(out, value);
						}
					}
				}
				row = body.nextRow(row);
				position++;
			}
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), position = 0;
			while (row >= 0) {
				var out = body.output(row), count = body.operandCount(row);
				switch body.opcode(row) {
					case IrOpcode.Call if (body.symbol(row).name == unboxName && count == 1
						&& reads.exists(body.operand(row, 0))
						&& IrValueArrayRows.typed(body, out, wrapperType) && uses[body.operand(row, 0)] == 1):
						var source = body.operand(row, 0), read = readAt(source);
						if (read.block == block && read.position < position) {
							unboxes.set(source, out);
							if (castSources.exists(source))
								rawReads.set(castSources.get(source), source);
						}
					case IrOpcode.ArraySet if (IrValueArrayRows.typed(body, body.operand(row, 0), arrayType)
						&& boxes.exists(body.operand(row, 2)) && uses[body.operand(row, 2)] == 1):
						var value = body.operand(row, 2), box = boxAt(value);
						if (box.block == block
							&& box.position < position
							&& privateWrapper(body, box.wrapper, block, box.position, value))
							writes.set(value, box.wrapper);
					case IrOpcode.Call if (mutation(body, row, arrayType) != null
						&& boxes.exists(body.operand(row, count - 1))
						&& uses[body.operand(row, count - 1)] == 1):
						var value = body.operand(row, count - 1), box = boxAt(value);
						if (box.block == block
							&& box.position < position
							&& privateWrapper(body, box.wrapper, block, box.position, value))
							writes.set(value, box.wrapper);
					case IrOpcode.Call if (mutation(body, row, arrayType) != null
						&& dynamicValues.exists(body.operand(row, count - 1))
						&& uses[body.operand(row, count - 1)] == 1):
						var conversion = dynamicValues.get(body.operand(row, count - 1));
						if (conversion == null)
							throw new InternalError("Missing optional dynamic array conversion");
						var box = boxes.get(conversion.boxed);
						if (box != null
							&& uses[conversion.boxed] == 1
							&& box.block == block
							&& conversion.block == block
							&& box.position < conversion.position
							&& conversion.position < position
							&& privateWrapper(body, box.wrapper, block, box.position, conversion.boxed)) {
							dynamicWrites.set(body.operand(row, count - 1), box.wrapper);
							dynamicBoxes.set(conversion.boxed, true);
						}
					default:
				}
				row = body.nextRow(row);
				position++;
			}
		}
		if (!unboxes.keys().hasNext() && !writes.keys().hasNext() && !dynamicWrites.keys().hasNext())
			return false;
		var voidType = body.typeId(Void);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var following = body.nextRow(row), out = body.output(row), count = body.operandCount(row);
				switch body.opcode(row) {
					case IrOpcode.ArrayGet if (unboxes.exists(out)):
						IrValueArrayRows.replaceByCall(body, block, row, unboxed(out), components.getName());
					case IrOpcode.Call:
						var callee = body.symbol(row).name;
						if ((rawReads.exists(out) || unboxes.exists(out))
							&& (callee == "__array_get_any" || callee == "__array_pop_ref"
							|| callee == "__array_shift_ref"
							|| callee == "__array_pop_any" || callee == "__array_shift_any")) {
							var id:Int = out;
							if (rawReads.exists(out)) {
								var source = rawReads.get(out);
								if (source == null)
									throw new InternalError("Missing raw optional array read");
								id = source;
							}
							var helper = switch readAt(id).operation {
								case "get": components.getName();
								case "pop": components.popName();
								case "shift": components.shiftName();
								default: throw new InternalError("Invalid optional array read");
							};
							IrValueArrayRows.replaceByCall(body, block, row, unboxed(id), helper);
						} else if (callee == unboxName && count == 1 && unboxes.exists(body.operand(row, 0))) {
							body.removeRow(block, row);
						} else if (callee == boxName && (writes.exists(out) || dynamicBoxes.exists(out))) {
							body.removeRow(block, row);
						} else if (mutation(body, row, arrayType) != null
							&& (writes.exists(body.operand(row, count - 1))
							|| dynamicWrites.exists(body.operand(row, count - 1)))) {
							var kind = mutation(body, row, arrayType),
								value = body.operand(row, count - 1),
								wrapper = writes.exists(value) ? writes.get(value) : dynamicWrites.get(value);
							if (wrapper == null)
								throw new InternalError("Missing optional array wrapper");
							var helper = switch kind {
								case "set": components.setName();
								case "push": components.pushName();
								case "insert": components.insertName();
								case "unshift": components.unshiftName();
								default: throw new InternalError("Invalid nullable array operation");
							};
							body.setOperation(row, IrOpcode.Call, IrSymbol.of(helper).id);
							body.setOperand(row, count - 1, wrapper);
						}
					case IrOpcode.SafeCast if (unboxes.exists(out) && castSources.exists(out)):
						body.removeRow(block, row);
					case IrOpcode.ToDyn if (dynamicWrites.exists(out)):
						body.removeRow(block, row);
					case IrOpcode.ArraySet if (writes.exists(body.operand(row, 2))):
						var wrapper = writes.get(body.operand(row, 2));
						if (wrapper == null)
							throw new InternalError("Missing optional array wrapper");
						IrValueArrayRows.call3(body, block, row,
							body.newValue("$optional-array-write", voidType),
							components.setName(), body.operand(row, 0), body.operand(row, 1), wrapper,
							body.provenance(row));
						body.removeRow(block, row);
					default:
				}
				row = following;
			}
		}
		IrValueArrayRows.removeBindings(body,
			value -> unboxes.exists(value) || writes.exists(value) || rawReads.exists(value)
			|| dynamicWrites.exists(value) || dynamicBoxes.exists(value));
		return true;
	}

	/** The array operation call `row` makes with a value as its last operand, when it is one, else null. */
	static function mutation(body:IrBody, row:Int, arrayType:Int):Null<String> {
		var count = body.operandCount(row);
		if (count == 0 || !IrValueArrayRows.typed(body, body.operand(row, 0), arrayType))
			return null;
		var name = body.symbol(row).name;
		var output = body.valueType(body.output(row));
		return switch name {
			case "__array_set_any" if (count == 3 && body.valueType(body.operand(row, 1)).match(I32)
				&& output.match(Void)): "set";
			case "__array_push_ref" | "__array_push_any" if (count == 2 && output.match(I32)): "push";
			case "__array_unshift_ref" | "__array_unshift_any" if (count == 2 && output.match(I32)): "unshift";
			case "__array_insert_ref"
				| "__array_insert_any" if (count == 3 && body.valueType(body.operand(row, 1)).match(I32)
				&& output.match(Void)): "insert";
			default: null;
		};
	}

	/** Whether `wrapper` is made in block `block` before the box at `boxPosition` and only filled in and boxed there. */
	static function privateWrapper(body:IrBody, wrapper:IrValueId, block:Int, boxPosition:Int, boxValue:Int):Bool {
		var allocated = false;
		for (current in 0...body.blockCount()) {
			var row = body.firstRow(current), position = 0;
			while (row >= 0) {
				var opcode = body.opcode(row);
				if (opcode == IrOpcode.ValueInit && body.output(row) == wrapper) {
					if (current != block || position >= boxPosition)
						return false;
					allocated = true;
				}
				for (index in 0...body.operandCount(row))
					if (body.operand(row, index) == wrapper) {
						var allowed = current == block && switch opcode {
							case IrOpcode.FieldSet: index == 0 && body.operand(row, 1) != wrapper
								&& position < boxPosition;
							case IrOpcode.Call: body.output(row) == boxValue && position == boxPosition;
							default: false;
						};
						if (!allowed)
							return false;
					}
				row = body.nextRow(row);
				position++;
			}
		}
		return allocated;
	}
}
