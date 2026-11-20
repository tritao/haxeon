package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;

/**
 * Appends the rows of an `IrBody`, block by block, and makes the body (`finish`). A body is never changed once made: a pass that
 * rewrites builds a new one. `encode` makes the body of an `IrFunction` through it. One builder serves many bodies: `finish`
 * copies its columns at their exact size and `reset` empties them without giving their storage back.
 */
@:allow(compiler.ir.IrBody)
class IrBodyBuilder {
	var types:IrTypeIds;
	final opcodes:Array<Int> = [];
	final outputs:Array<Int> = [];
	final auxes:Array<Int> = [];
	final provenances:Array<Int> = [];

	/** Where each row's operands start in `operands`, and one more entry, where the next row's would. */
	final operandStarts:Array<Int> = [0];

	final operands:Array<Int> = [];
	final ints:Array<Int> = [];
	final floats:Array<Float> = [];
	final strings:Array<String> = [];
	final provenancePool:Array<SourceProvenance> = [];

	final blockIds:Array<Int> = [];

	/** Each block's first row, and one more entry when finished, the row count. */
	final blockStarts:Array<Int> = [];

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

	public function new(types:IrTypeIds)
		this.types = types;

	/** Empties the builder for another body, whose types are numbered in `types`. */
	public function reset(types:IrTypeIds):Void {
		this.types = types;
		opcodes.resize(0);
		outputs.resize(0);
		auxes.resize(0);
		provenances.resize(0);
		operandStarts.resize(1);
		operands.resize(0);
		ints.resize(0);
		floats.resize(0);
		strings.resize(0);
		provenancePool.resize(0);
		blockIds.resize(0);
		blockStarts.resize(0);
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
	public static function encode(fn:IrFunction, types:IrTypeIds, ?builder:IrBodyBuilder):IrBody {
		if (builder == null)
			builder = new IrBodyBuilder(types);
		else
			builder.reset(types);
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

	public inline function rowCount():Int
		return opcodes.length;

	public function beginBlock(id:Int):Void {
		blockIds.push(id);
		blockStarts.push(opcodes.length);
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
			valueTypes[id] = types.id(value.type);
			valueNames[id] = value.name;
		}
		return id;
	}

	public inline function operand(value:IrValue):Void
		operands.push(this.value(value));

	/** Ends a row whose operands were added before it; `output` is a value id or -1. */
	public function row(opcode:IrOpcode, output:Int, aux:Int, provenance:SourceProvenance):Void {
		var row = opcodes.length;
		if (output >= 0 && valueRows[output] < 0)
			valueRows[output] = row;
		opcodes.push(opcode);
		outputs.push(output);
		auxes.push(aux);
		var last = provenancePool.length - 1;
		if (last < 0 || provenancePool[last] != provenance) {
			provenancePool.push(provenance);
			last++;
		}
		provenances.push(last);
		operandStarts.push(operands.length);
	}

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
			retention:IrRetention):IrBody {
		blockStarts.push(opcodes.length);
		var body = new IrBody(this, name, kind, types.id(result), inlineHint, retention);
		blockStarts.pop();
		return body;
	}

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
				row(IrOpcode.TypeValue, value(output), types.id(type), where);
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
						row(IrOpcode.EnumDynamicBox, value(output), types.id(type), where);
					case EnumDynamicView(type):
						row(IrOpcode.EnumDynamicView, value(output), types.id(type), where);
					case EnumTagBox(type):
						row(IrOpcode.EnumTagBox, value(output), types.id(type), where);
					case EnumTagUnbox(type):
						row(IrOpcode.EnumTagUnbox, value(output), types.id(type), where);
					case InlineEnumBox(type):
						row(IrOpcode.InlineEnumBox, value(output), types.id(type), where);
					case InlineEnumUnbox(type):
						row(IrOpcode.InlineEnumUnbox, value(output), types.id(type), where);
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
