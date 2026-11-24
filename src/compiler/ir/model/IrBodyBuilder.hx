package compiler.ir.model;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.IrFunction;
import compiler.ir.model.SourceProvenance;
import compiler.ir.model.SourceProvenance.Located;

/**
 * Appends the rows of an `IrBody`, block by block, and makes the body (`finish`): `encode` makes the body of an `IrFunction`
 * through it, and `compact` a copy of a body without what its edits left behind. One builder serves many bodies: `finish` copies
 * its columns at their exact size and `reset` empties them without giving their storage back.
 */
@:allow(compiler.ir.model.IrBody)
@:nullSafety(Strict)
class IrBodyBuilder {
	final opcodes:Array<Int> = [];
	final outputs:Array<Int> = [];
	final auxes:Array<Int> = [];
	final provenances:Array<Int> = [];

	/** Where each row's operands start and end in `operands`. */
	final operandStarts:Array<Int> = [];

	final operandEnds:Array<Int> = [];

	/** Each row's neighbours in its block, -1 at the ends. */
	final previousRows:Array<Int> = [];

	final nextRows:Array<Int> = [];

	/** Where the operands of the row being built start. */
	var operandsFrom = 0;

	final operands:Array<Int> = [];
	final ints:Array<Int> = [];
	final floats:Array<Float> = [];
	final strings:Array<String> = [];
	final provenancePool:Array<SourceProvenance> = [];

	final blockIds:Array<Int> = [];

	/** Each block's first and last row, -1 while it has none. */
	final blockFirstRows:Array<Int> = [];

	final blockLastRows:Array<Int> = [];

	/** By value id: its type id, or -1 for an id no value has. */
	final valueTypes:Array<Int> = [];

	final valueNames:Array<String> = [];

	/** By value id: the row that defines it, or -1 (an argument, or a value the body uses without defining). */
	final valueRows:Array<Int> = [];

	final argumentIds:Array<Int> = [];
	final bindingIdentities:Array<String> = [];
	final bindingNames:Array<String> = [];
	final bindingPaths:Array<String> = [];
	final bindingStarts:Array<Int> = [];
	final bindingEnds:Array<Int> = [];
	final bindingValues:Array<Int> = [];

	/** By value id of the body being renumbered, its new id or -1 (`renumbered`). */
	final renumbering:Array<Int> = [];

	public function new() {}

	/** Empties the builder for another body. */
	public function reset():Void {
		opcodes.resize(0);
		outputs.resize(0);
		auxes.resize(0);
		provenances.resize(0);
		operandStarts.resize(0);
		operandEnds.resize(0);
		previousRows.resize(0);
		nextRows.resize(0);
		operandsFrom = 0;
		operands.resize(0);
		ints.resize(0);
		floats.resize(0);
		strings.resize(0);
		provenancePool.resize(0);
		blockIds.resize(0);
		blockFirstRows.resize(0);
		blockLastRows.resize(0);
		valueTypes.resize(0);
		valueNames.resize(0);
		valueRows.resize(0);
		argumentIds.resize(0);
		bindingIdentities.resize(0);
		bindingNames.resize(0);
		bindingPaths.resize(0);
		bindingStarts.resize(0);
		bindingEnds.resize(0);
		bindingValues.resize(0);
	}

	/** The body of `fn`, every value, row and binding of it, in its order; made with `builder` when given, which is reset first. */
	public static function encode(fn:IrFunction, ?builder:IrBodyBuilder):IrBody {
		if (builder == null)
			builder = new IrBodyBuilder();
		else
			builder.reset();
		for (argument in fn.arguments)
			builder.argumentIds.push(builder.value(argument));
		for (block in fn.blocks) {
			builder.beginBlock(block.id);
			for (instruction in block.instructions)
				builder.instruction(instruction);
			var terminator = block.terminator;
			if (terminator != null)
				builder.terminator(terminator);
		}
		for (binding in fn.debugBindings)
			builder.binding(binding);
		return builder.finish(fn.name, fn.kind, fn.result, fn.inlineHint, fn.retention);
	}

	/**
	 * Empties the builder for a copy of `source`: the new body keeps its arguments, and every value of it under the same id, name
	 * and type, so rows can be copied as they are. Rows, blocks and bindings start empty.
	 */
	public function startFrom(source:IrBody):Void {
		reset();
		var count = source.valueTypes.length;
		valueTypes.resize(count);
		valueNames.resize(count);
		valueRows.resize(count);
		for (id in 0...count) {
			valueTypes[id] = source.valueTypes[id];
			valueNames[id] = source.valueNames[id];
			valueRows[id] = -1;
		}
		for (argument in source.argumentIds)
			argumentIds.push(argument);
	}

	/** Appends `id` to the operands of the row being built. */
	public inline function operandId(id:IrValueId):Void
		operands.push(id);

	/**
	 * Appends `source`'s row `row` unchanged but for its operands, each replaced by `substitution[id]` when that is not -1 (when
	 * a substitution is given). Its pool entries are copied, so the row means here what it meant there.
	 */
	public function copyRow(source:IrBody, row:Int, ?substitution:Array<Int>):Void {
		var start = source.operandStarts[row], end = source.operandEnds[row];
		for (index in start...end) {
			var id = source.operandPool[index];
			if (substitution != null && id < substitution.length && substitution[id] >= 0)
				id = substitution[id];
			operands.push(id);
		}
		this.row(source.opcode(row), source.outputs[row], copyAux(source, row), source.provenance(row));
	}

	/** `source`'s row's auxiliary field, its pool entries copied to this builder's pools. */
	public function copyAux(source:IrBody, row:Int):Int {
		var aux = source.auxes[row];
		return switch source.opcode(row) {
			case IrOpcode.ConstFloat:
				floats.push(source.floats[aux]);
				floats.length - 1;
			case IrOpcode.ConstString:
				strings.push(source.strings[aux]);
				strings.length - 1;
			case IrOpcode.Phi:
				copyInts(source, aux, source.operandCount(row));
			case IrOpcode.StaticDataAddress:
				copyInts(source, aux, 1 + source.ints[aux]);
			case IrOpcode.BeginTry:
				copyInts(source, aux, 3);
			case IrOpcode.EndTry, IrOpcode.MakeEnum, IrOpcode.EnumField, IrOpcode.Branch:
				copyInts(source, aux, 2);
			case IrOpcode.Switch:
				copyInts(source, aux, 2 + source.ints[aux + 1]);
			default:
				aux;
		};
	}

	function copyInts(source:IrBody, start:Int, count:Int):Int {
		var result = ints.length;
		for (index in start...start + count)
			ints.push(source.ints[index]);
		return result;
	}

	/** Appends `source`'s debug binding `index`, its value replaced by `value`. */
	public function copyBinding(source:IrBody, index:Int, value:IrValueId):Void {
		bindingIdentities.push(source.bindingIdentities[index]);
		bindingNames.push(source.bindingNames[index]);
		bindingPaths.push(source.bindingPaths[index]);
		bindingStarts.push(source.bindingStarts[index]);
		bindingEnds.push(source.bindingEnds[index]);
		bindingValues.push(value);
	}

	/** Gives value `id` (a new one, or one of the source's, `startFrom`) a name and a type id. */
	public function defineValue(value:IrValueId, name:String, typeId:Int):Void {
		var id:Int = value;
		if (valueTypes.length <= id) {
			var from = valueTypes.length;
			valueTypes.resize(id + 1);
			valueNames.resize(id + 1);
			valueRows.resize(id + 1);
			for (index in from...id + 1) {
				valueTypes[index] = -1;
				valueRows[index] = -1;
			}
		}
		valueTypes[id] = typeId;
		valueNames[id] = name;
	}

	/** Empties the arguments, for a body whose arguments differ from its source's (`startFrom`). */
	public inline function clearArguments():Void
		argumentIds.resize(0);

	public inline function addArgument(id:IrValueId):Void
		argumentIds.push(id);

	/** Adds a float to the pool and gives its index, for a `ConstFloat` row's auxiliary field. */
	public inline function float(value:Float):Int {
		floats.push(value);
		return floats.length - 1;
	}

	/** The body made, named `name`, its result the type with id `result`: for a body rebuilt from a source (`startFrom`). */
	public function finishAs(name:String, kind:IrFunctionKind, result:Int, inlineHint:Bool,
			retention:IrRetention):IrBody
		return new IrBody(this, name, kind, result, inlineHint, retention);

	/** The body made, with `source`'s name, kind, result and flags. */
	public function finishFrom(source:IrBody):IrBody
		return new IrBody(this, source.name, source.kind, source.result, source.inlineHint, source.retention);

	/** `source` without the rows its edits unlinked or the runs they left: its blocks, rows and bindings in order, rebuilt. */
	public static function compact(source:IrBody, ?builder:IrBodyBuilder):IrBody {
		if (builder == null)
			builder = new IrBodyBuilder();
		builder.startFrom(source);
		for (block in 0...source.blockCount()) {
			builder.beginBlock(source.blockId(block));
			var row = source.firstRow(block);
			while (row >= 0) {
				builder.copyRow(source, row);
				row = source.nextRow(row);
			}
		}
		for (index in 0...source.bindingCount())
			builder.copyBinding(source, index, source.bindingValue(index));
		return builder.finishFrom(source);
	}

	/**
	 * `source` compacted, with its values numbered in the order they first appear: the arguments, then each row's output in
	 * block and row order, then the values only operands or bindings name. A reader that orders anything by value id then
	 * depends on the code alone, not on the ids the passes gave the values they made.
	 */
	public static function renumbered(source:IrBody, ?builder:IrBodyBuilder):IrBody {
		if (builder == null)
			builder = new IrBodyBuilder();
		builder.reset();
		var ids = IrPassScratch.filledInts(builder.renumbering, source.valueLimit(), -1);
		for (index in 0...source.argumentCount())
			builder.argumentIds.push(builder.renumber(source, ids, source.argument(index)));
		for (block in 0...source.blockCount()) {
			var row = source.firstRow(block);
			while (row >= 0) {
				var output = source.output(row);
				if (output.exists())
					builder.renumber(source, ids, output);
				row = source.nextRow(row);
			}
		}
		for (block in 0...source.blockCount()) {
			builder.beginBlock(source.blockId(block));
			var row = source.firstRow(block);
			while (row >= 0) {
				for (index in 0...source.operandCount(row))
					builder.operands.push(builder.renumber(source, ids, source.operand(row, index)));
				var output = source.output(row);
				builder.row(source.opcode(row), output.exists() ? ids[output] : -1, builder.copyAux(source, row),
					source.provenance(row));
				row = source.nextRow(row);
			}
		}
		for (index in 0...source.bindingCount())
			builder.copyBinding(source, index, IrValueId.of(builder.renumber(source, ids, source.bindingValue(index))));
		return builder.finishFrom(source);
	}

	/** The new id of `source`'s value `id` (`renumbered`), the next one when it has none yet. */
	function renumber(source:IrBody, ids:Array<Int>, id:Int):Int {
		var known = ids[id];
		if (known >= 0)
			return known;
		var result = valueTypes.length;
		ids[id] = result;
		valueTypes.push(source.valueTypes[id]);
		valueNames.push(source.valueNames[id]);
		valueRows.push(-1);
		return result;
	}

	/** A copy of `source` column for column, for a body no edit touched: the same rows, runs and pools where they were. */
	/** A copy of `source` with the same layout, column for column, which no edit made: freezing it keeps it as it is. */
	public static function copy(source:IrBody, ?builder:IrBodyBuilder):IrBody {
		if (builder == null)
			builder = new IrBodyBuilder();
		builder.reset();
		copyColumn(builder.opcodes, source.opcodes);
		copyColumn(builder.outputs, source.outputs);
		copyColumn(builder.auxes, source.auxes);
		copyColumn(builder.provenances, source.provenances);
		copyColumn(builder.operandStarts, source.operandStarts);
		copyColumn(builder.operandEnds, source.operandEnds);
		copyColumn(builder.previousRows, source.previousRows);
		copyColumn(builder.nextRows, source.nextRows);
		copyColumn(builder.operands, source.operandPool);
		copyColumn(builder.ints, source.ints);
		for (value in source.floats)
			builder.floats.push(value);
		for (value in source.strings)
			builder.strings.push(value);
		for (value in source.provenancePool)
			builder.provenancePool.push(value);
		copyColumn(builder.blockIds, source.blockIds);
		copyColumn(builder.blockFirstRows, source.blockFirstRows);
		copyColumn(builder.blockLastRows, source.blockLastRows);
		copyColumn(builder.valueTypes, source.valueTypes);
		for (name in source.valueNames)
			builder.valueNames.push(name);
		copyColumn(builder.valueRows, source.valueRows);
		copyColumn(builder.argumentIds, source.argumentIds);
		for (index in 0...source.bindingIdentities.length) {
			builder.bindingIdentities.push(source.bindingIdentities[index]);
			builder.bindingNames.push(source.bindingNames[index]);
			builder.bindingPaths.push(source.bindingPaths[index]);
		}
		copyColumn(builder.bindingStarts, source.bindingStarts);
		copyColumn(builder.bindingEnds, source.bindingEnds);
		copyColumn(builder.bindingValues, source.bindingValues);
		builder.operandsFrom = builder.operands.length;
		return builder.finishFrom(source);
	}

	static function copyColumn(into:Array<Int>, from:Array<Int>):Void {
		into.resize(from.length);
		for (index in 0...from.length)
			into[index] = from[index];
	}

	public function beginBlock(id:Int):Void {
		blockIds.push(id);
		blockFirstRows.push(-1);
		blockLastRows.push(-1);
	}

	/** Declares `value` (its name and type kept the first time its id is seen) and gives its id. */
	public function value(value:IrValue):Int {
		var id = value.id;
		if (id < 0)
			throw new InternalError('IR body value ${value.name} has a negative id');
		if (valueTypes.length <= id) {
			var from = valueTypes.length;
			valueTypes.resize(id + 1);
			valueNames.resize(id + 1);
			valueRows.resize(id + 1);
			for (index in from...id + 1) {
				valueTypes[index] = -1;
				valueRows[index] = -1;
			}
		}
		if (valueTypes[id] < 0) {
			valueTypes[id] = IrTypeIds.id(value.type);
			valueNames[id] = value.name;
		}
		return id;
	}

	public inline function operand(value:IrValue):Void
		operands.push(this.value(value));

	/** Ends a row of the last block begun, whose operands were added before it; `output` is a value id or -1. */
	public function row(opcode:IrOpcode, output:Int, aux:Int, provenance:SourceProvenance):Void {
		var row = opcodes.length, block = blockIds.length - 1, previous = blockLastRows[block];
		if (output >= 0 && valueRows[output] < 0)
			valueRows[output] = row;
		previousRows.push(previous);
		nextRows.push(-1);
		if (previous >= 0)
			nextRows[previous] = row;
		else
			blockFirstRows[block] = row;
		blockLastRows[block] = row;
		opcodes.push(opcode);
		outputs.push(output);
		auxes.push(aux);
		var last = provenancePool.length - 1;
		if (last < 0 || provenancePool[last] != provenance) {
			provenancePool.push(provenance);
			last++;
		}
		provenances.push(last);
		operandStarts.push(operandsFrom);
		operandEnds.push(operands.length);
		operandsFrom = operands.length;
	}

	/** Where the next entry of the int pool goes: the auxiliary field of a row whose run starts there. */
	public inline function poolStart():Int
		return ints.length;

	/** Appends `value` to the int pool and gives its index. */
	public inline function int(value:Int):Int {
		ints.push(value);
		return ints.length - 1;
	}

	public function binding(binding:IrDebugBinding):Void {
		bindingIdentities.push(binding.identity);
		bindingNames.push(binding.name);
		bindingPaths.push(binding.path);
		bindingStarts.push(binding.scopeStart);
		bindingEnds.push(binding.scopeEnd);
		bindingValues.push(value(binding.value));
	}

	public function finish(name:String, kind:IrFunctionKind, result:IrType, inlineHint:Bool,
			retention:IrRetention):IrBody
		return new IrBody(this, name, kind, IrTypeIds.id(result), inlineHint, retention);

	static inline function symbol(name:String):Int
		return IrSymbol.of(name).id;

	function operands2(a:IrValue, b:IrValue):Void {
		operand(a);
		operand(b);
	}

	function operandList(values:Array<IrValue>):Void {
		for (value in values)
			operand(value);
	}

	public function instruction(located:Located<IrInstruction>):Void {
		var where = located.provenance;
		switch located.value {
			case Phi(output, inputs):
				var start = ints.length;
				for (input in inputs) {
					operand(input.value);
					ints.push(input.block);
				}
				row(IrOpcode.Phi, value(output), start, where);
			case ConstVoid(output):
				row(IrOpcode.ConstVoid, value(output), 0, where);
			case ConstInt(output, number):
				row(IrOpcode.ConstInt, value(output), number, where);
			case ConstFloat(output, number):
				floats.push(number);
				row(IrOpcode.ConstFloat, value(output), floats.length - 1, where);
			case ConstString(output, text):
				strings.push(text);
				row(IrOpcode.ConstString, value(output), strings.length - 1, where);
			case StaticDataAddress(output, bytes):
				var start = int(bytes.length);
				for (byte in bytes)
					ints.push(byte);
				row(IrOpcode.StaticDataAddress, value(output), start, where);
			case PointerOffset(output, pointer, offset):
				operands2(pointer, offset);
				row(IrOpcode.PointerOffset, value(output), 0, where);
			case MemoryLoad(output, pointer, size, signed):
				operand(pointer);
				row(IrOpcode.MemoryLoad, value(output), size << 1 | (signed ? 1 : 0), where);
			case MemoryStore(pointer, stored, size):
				operands2(pointer, stored);
				row(IrOpcode.MemoryStore, -1, size, where);
			case ConstBool(output, state):
				row(IrOpcode.ConstBool, value(output), state ? 1 : 0, where);
			case ConstNull(output):
				row(IrOpcode.ConstNull, value(output), 0, where);
			case TypeValue(output, type):
				row(IrOpcode.TypeValue, value(output), IrTypeIds.id(type), where);
			case ToDyn(output, input):
				unary(IrOpcode.ToDyn, output, input, where);
			case IntToFloat(output, input):
				unary(IrOpcode.IntToFloat, output, input, where);
			case IntToInt64(output, input):
				unary(IrOpcode.IntToInt64, output, input, where);
			case FloatToInt(output, input):
				unary(IrOpcode.FloatToInt, output, input, where);
			case FloatToFloat(output, input):
				unary(IrOpcode.FloatToFloat, output, input, where);
			case SafeCast(output, input):
				unary(IrOpcode.SafeCast, output, input, where);
			case BeginTry(catchBlock, afterBlock, preserve):
				var start = int(catchBlock);
				ints.push(afterBlock);
				ints.push(preserve ? 1 : 0);
				row(IrOpcode.BeginTry, -1, start, where);
			case EndTry(catchBlock, preserve):
				var start = int(catchBlock);
				ints.push(preserve ? 1 : 0);
				row(IrOpcode.EndTry, -1, start, where);
			case Catch(output):
				row(IrOpcode.Catch, value(output), 0, where);
			case GlobalGet(output, name):
				row(IrOpcode.GlobalGet, value(output), symbol(name), where);
			case GlobalSet(name, stored):
				operand(stored);
				row(IrOpcode.GlobalSet, -1, symbol(name), where);
			case Add(output, left, right):
				binary(IrOpcode.Add, output, left, right, where);
			case Sub(output, left, right):
				binary(IrOpcode.Sub, output, left, right, where);
			case Mul(output, left, right):
				binary(IrOpcode.Mul, output, left, right, where);
			case Div(output, left, right):
				binary(IrOpcode.Div, output, left, right, where);
			case Mod(output, left, right):
				binary(IrOpcode.Mod, output, left, right, where);
			case BitAnd(output, left, right):
				binary(IrOpcode.BitAnd, output, left, right, where);
			case BitXor(output, left, right):
				binary(IrOpcode.BitXor, output, left, right, where);
			case BitOr(output, left, right):
				binary(IrOpcode.BitOr, output, left, right, where);
			case ShiftLeft(output, left, right):
				binary(IrOpcode.ShiftLeft, output, left, right, where);
			case ShiftRight(output, left, right):
				binary(IrOpcode.ShiftRight, output, left, right, where);
			case UnsignedShiftRight(output, left, right):
				binary(IrOpcode.UnsignedShiftRight, output, left, right, where);
			case Less(output, left, right):
				binary(IrOpcode.Less, output, left, right, where);
			case LessEqual(output, left, right):
				binary(IrOpcode.LessEqual, output, left, right, where);
			case Equal(output, left, right):
				binary(IrOpcode.Equal, output, left, right, where);
			case Call(output, target, arguments):
				operandList(arguments);
				row(IrOpcode.Call, value(output), target.id, where);
			case CNativeCall(output, name, arguments):
				operandList(arguments);
				row(IrOpcode.CNativeCall, value(output), symbol(name), where);
			case StaticClosure(output, target):
				row(IrOpcode.StaticClosure, value(output), target.id, where);
			case InstanceClosure(output, target, receiver):
				operand(receiver);
				row(IrOpcode.InstanceClosure, value(output), target.id, where);
			case CallClosure(output, closure, arguments):
				operand(closure);
				operandList(arguments);
				row(IrOpcode.CallClosure, value(output), 0, where);
			case ToVirtual(output, input):
				unary(IrOpcode.ToVirtual, output, input, where);
			case Upcast(output, input):
				unary(IrOpcode.Upcast, output, input, where);
			case ClassId(output, input):
				unary(IrOpcode.ClassId, output, input, where);
			case MethodCall(output, object, name, arguments, terminal):
				operand(object);
				operandList(arguments);
				row(IrOpcode.MethodCall, value(output), symbol(name) << 1 | (terminal ? 1 : 0), where);
			case NewObject(output, name):
				row(IrOpcode.NewObject, value(output), symbol(name), where);
			case ValueInit(output):
				row(IrOpcode.ValueInit, value(output), 0, where);
			case FieldGet(output, object, name):
				operand(object);
				row(IrOpcode.FieldGet, value(output), symbol(name), where);
			case FieldSet(object, name, stored):
				operands2(object, stored);
				row(IrOpcode.FieldSet, -1, symbol(name), where);
			case ArrayGet(output, array, index):
				binary(IrOpcode.ArrayGet, output, array, index, where);
			case ArraySet(array, index, stored):
				operands2(array, index);
				operand(stored);
				row(IrOpcode.ArraySet, -1, 0, where);
			case ArraySize(output, array):
				unary(IrOpcode.ArraySize, output, array, where);
			case IteratorNew(output, array):
				unary(IrOpcode.IteratorNew, output, array, where);
			case IteratorHasNext(output, iterator):
				unary(IrOpcode.IteratorHasNext, output, iterator, where);
			case IteratorNext(output, iterator):
				unary(IrOpcode.IteratorNext, output, iterator, where);
			case MakeEnum(output, name, constructor, arguments):
				operandList(arguments);
				var start = int(symbol(name));
				ints.push(constructor);
				row(IrOpcode.MakeEnum, value(output), start, where);
			case EnumIndex(output, input):
				unary(IrOpcode.EnumIndex, output, input, where);
			case EnumField(output, input, constructor, field):
				operand(input);
				var start = int(constructor);
				ints.push(field);
				row(IrOpcode.EnumField, value(output), start, where);
			case Intrinsic(output, operation, arguments):
				operandList(arguments);
				switch operation {
					case EnumDynamicBox(type):
						row(IrOpcode.EnumDynamicBox, value(output), IrTypeIds.id(type), where);
					case EnumDynamicView(type):
						row(IrOpcode.EnumDynamicView, value(output), IrTypeIds.id(type), where);
					case EnumTagBox(type):
						row(IrOpcode.EnumTagBox, value(output), IrTypeIds.id(type), where);
					case EnumTagUnbox(type):
						row(IrOpcode.EnumTagUnbox, value(output), IrTypeIds.id(type), where);
					case InlineEnumBox(type):
						row(IrOpcode.InlineEnumBox, value(output), IrTypeIds.id(type), where);
					case InlineEnumUnbox(type):
						row(IrOpcode.InlineEnumUnbox, value(output), IrTypeIds.id(type), where);
				}
		}
	}

	public function terminator(located:Located<IrTerminator>):Void {
		var where = located.provenance;
		switch located.value {
			case Unreachable:
				row(IrOpcode.Unreachable, -1, 0, where);
			case Return(input):
				operand(input);
				row(IrOpcode.Return, -1, 0, where);
			case Throw(input):
				operand(input);
				row(IrOpcode.Throw, -1, 0, where);
			case Rethrow(input):
				operand(input);
				row(IrOpcode.Rethrow, -1, 0, where);
			case Jump(target):
				row(IrOpcode.Jump, -1, target, where);
			case Branch(condition, whenTrue, whenFalse):
				operand(condition);
				var start = int(whenTrue);
				ints.push(whenFalse);
				row(IrOpcode.Branch, -1, start, where);
			case Switch(input, targets, otherwise):
				operand(input);
				var start = int(otherwise);
				ints.push(targets.length);
				for (target in targets)
					ints.push(target);
				row(IrOpcode.Switch, -1, start, where);
		}
	}

	function unary(opcode:IrOpcode, output:IrValue, input:IrValue, where:SourceProvenance):Void {
		operand(input);
		row(opcode, value(output), 0, where);
	}

	function binary(opcode:IrOpcode, output:IrValue, left:IrValue, right:IrValue, where:SourceProvenance):Void {
		operands2(left, right);
		row(opcode, value(output), 0, where);
	}
}
