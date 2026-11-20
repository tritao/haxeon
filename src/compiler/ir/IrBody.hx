package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;

/**
 * A function body as a table (docs/design/IR_CORE_COLUMNS.md): one row per instruction or terminator in parallel `Int` columns
 * (opcode, output value id or -1, operand range in one operand pool, auxiliary field, provenance id), blocks as ranges of rows,
 * values as ids with their name, type and defining row in columns indexed by id. Immutable once built (`IrBodyBuilder`).
 *
 * The auxiliary field by opcode: a constant (`ConstInt`, `ConstBool` 0 or 1, `MemoryStore` size, `MemoryLoad` size << 1 | signed,
 * `Jump` target); an index into the float or string pool (`ConstFloat`, `ConstString`); a type id (`TypeValue`, the intrinsics);
 * a symbol id (`Call`, `StaticClosure`, `InstanceClosure`, `CNativeCall`, `GlobalGet`, `GlobalSet`, `NewObject`, `FieldGet`,
 * `FieldSet`; `MethodCall` as symbol << 1 | terminal receiver); or the start of a run in the int pool: `Phi` one predecessor block
 * per operand, `StaticDataAddress` [count, bytes], `BeginTry` [catch, after, preserve], `EndTry` [catch, preserve], `MakeEnum`
 * [type symbol, constructor], `EnumField` [constructor, field], `Branch` [when true, when false], `Switch` [otherwise, count,
 * targets]. Operands are the instruction's values in the order `IrInstruction` declares them, the output left out.
 */
@:allow(compiler.ir.IrBodyBuilder)
class IrBody {
	public final name:String;
	public final kind:IrFunctionKind;
	public final inlineHint:Bool;
	public final retention:IrRetention;

	/** The type id of the function's result. */
	public final result:Int;

	/** The program's type ids, which this body's type ids index. */
	public final types:IrTypeIds;

	final opcodes:Array<Int>;
	final outputs:Array<Int>;
	final auxes:Array<Int>;
	final provenances:Array<Int>;
	final operandStarts:Array<Int>;
	final operandPool:Array<Int>;
	final ints:Array<Int>;
	final floats:Array<Float>;
	final strings:Array<String>;
	final provenancePool:Array<SourceProvenance>;
	final blockIds:Array<Int>;
	final blockStarts:Array<Int>;
	final valueTypes:Array<Int>;
	final valueNames:Array<String>;
	final valueRows:Array<Int>;
	final argumentIds:Array<Int>;
	final bindingIdentities:Array<String>;
	final bindingNames:Array<String>;
	final bindingPaths:Array<String>;
	final bindingStarts:Array<Int>;
	final bindingEnds:Array<Int>;
	final bindingValues:Array<Int>;

	/** Copies the builder's columns at their exact size. */
	function new(builder:IrBodyBuilder, name:String, kind:IrFunctionKind, result:Int, inlineHint:Bool,
			retention:IrRetention) {
		this.name = name;
		this.kind = kind;
		this.result = result;
		this.inlineHint = inlineHint;
		this.retention = retention;
		types = builder.types;
		opcodes = builder.opcodes.copy();
		outputs = builder.outputs.copy();
		auxes = builder.auxes.copy();
		provenances = builder.provenances.copy();
		operandStarts = builder.operandStarts.copy();
		operandPool = builder.operands.copy();
		ints = builder.ints.copy();
		floats = builder.floats.copy();
		strings = builder.strings.copy();
		provenancePool = builder.provenancePool.copy();
		blockIds = builder.blockIds.copy();
		blockStarts = builder.blockStarts.copy();
		valueTypes = builder.valueTypes.copy();
		valueNames = builder.valueNames.copy();
		valueRows = builder.valueRows.copy();
		argumentIds = builder.argumentIds.copy();
		bindingIdentities = builder.bindingIdentities.copy();
		bindingNames = builder.bindingNames.copy();
		bindingPaths = builder.bindingPaths.copy();
		bindingStarts = builder.bindingStarts.copy();
		bindingEnds = builder.bindingEnds.copy();
		bindingValues = builder.bindingValues.copy();
	}

	// Rows.

	public inline function rowCount():Int
		return opcodes.length;

	public inline function opcode(row:Int):IrOpcode
		return opcodes[row];

	/** The value id the row defines, or -1. */
	public inline function output(row:Int):Int
		return outputs[row];

	public inline function operandCount(row:Int):Int
		return operandStarts[row + 1] - operandStarts[row];

	/** The value id of the row's operand `index`. */
	public inline function operand(row:Int, index:Int):Int
		return operandPool[operandStarts[row] + index];

	public inline function aux(row:Int):Int
		return auxes[row];

	/** Entry `index` of the row's run in the int pool, for the opcodes whose auxiliary field starts one. */
	public inline function auxInt(row:Int, index:Int):Int
		return ints[auxes[row] + index];

	public inline function provenance(row:Int):SourceProvenance
		return provenancePool[provenances[row]];

	public inline function float(row:Int):Float
		return floats[auxes[row]];

	public inline function string(row:Int):String
		return strings[auxes[row]];

	/** The name a row refers to, for the opcodes whose auxiliary field is a symbol id. */
	public function symbol(row:Int):IrSymbol
		return IrSymbol.at(switch opcode(row) {
			case IrOpcode.MethodCall: auxes[row] >> 1;
			case IrOpcode.MakeEnum: auxInt(row, 0);
			default: auxes[row];
		});

	/** The type a `TypeValue` row or an intrinsic names. */
	public inline function typeOperand(row:Int):IrType
		return types.type(auxes[row]);

	/** How many blocks a terminator row can go to. */
	public function successorCount(row:Int):Int
		return switch opcode(row) {
			case IrOpcode.Jump: 1;
			case IrOpcode.Branch: 2;
			case IrOpcode.Switch: auxInt(row, 1) + 1;
			default: 0;
		};

	/** The block id of a terminator's successor `index`; a switch's targets come first, then its otherwise. */
	public function successor(row:Int, index:Int):Int
		return switch opcode(row) {
			case IrOpcode.Jump: auxes[row];
			case IrOpcode.Branch: auxInt(row, index);
			case IrOpcode.Switch: index < auxInt(row, 1) ? auxInt(row, 2 + index) : auxInt(row, 0);
			default: throw new InternalError('IR body row $row has no successors');
		};

	// Blocks, in function order.

	public inline function blockCount():Int
		return blockIds.length;

	public inline function blockId(block:Int):Int
		return blockIds[block];

	public inline function firstRow(block:Int):Int
		return blockStarts[block];

	/** The row after the block's last one. */
	public inline function endRow(block:Int):Int
		return blockStarts[block + 1];

	/** The block's terminator row, or -1 when it has none yet. */
	public function terminatorRow(block:Int):Int {
		var last = blockStarts[block + 1] - 1;
		return last >= blockStarts[block] && opcode(last).isTerminator() ? last : -1;
	}

	/** The row after the block's last instruction: its terminator row, or its end when it has none. */
	public function instructionEnd(block:Int):Int {
		var terminator = terminatorRow(block);
		return terminator >= 0 ? terminator : blockStarts[block + 1];
	}

	// Values.

	/** Every value id is below it. */
	public inline function valueLimit():Int
		return valueTypes.length;

	public inline function hasValue(value:Int):Bool
		return value < valueTypes.length && valueTypes[value] >= 0;

	public inline function valueTypeId(value:Int):Int
		return valueTypes[value];

	public inline function valueType(value:Int):IrType
		return types.type(valueTypes[value]);

	public inline function valueName(value:Int):String
		return valueNames[value];

	/** The row defining the value, or -1 for an argument or a value used without a definition here. */
	public inline function definingRow(value:Int):Int
		return valueRows[value];

	public inline function argumentCount():Int
		return argumentIds.length;

	public inline function argument(index:Int):Int
		return argumentIds[index];

	// Debug bindings.

	public inline function bindingCount():Int
		return bindingIdentities.length;

	public inline function bindingValue(index:Int):Int
		return bindingValues[index];

	/** The `IrFunction` this body is the table of, equal to the encoded one (`IrFunctionStateEquality.same`). */
	public function toFunction():IrFunction {
		var values:Array<Null<IrValue>> = [];
		values.resize(valueTypes.length);
		var blocks:Array<IrBlock> = [];
		for (block in 0...blockIds.length) {
			var end = blockStarts[block + 1], terminator = terminatorRow(block);
			if (terminator >= 0)
				end = terminator;
			var instructions:Array<Located<IrInstruction>> = [];
			for (row in blockStarts[block]...end)
				instructions.push(new Located(decodeInstruction(row, values), provenance(row)));
			var decoded = new IrBlock(blockIds[block], instructions);
			if (terminator >= 0)
				decoded.terminator = new Located(decodeTerminator(terminator, values), provenance(terminator));
			blocks.push(decoded);
		}
		var bindings:Array<IrDebugBinding> = [for (index in 0...bindingIdentities.length)
			{
				identity:bindingIdentities[index],
					name:bindingNames[index],
					value:valueOf(bindingValues[index], values),
					path:bindingPaths[index],
					scopeStart:bindingStarts[index],
					scopeEnd:bindingEnds[index]
			}];
		return new IrFunction(name, [for (id in argumentIds) valueOf(id, values)], types.type(result), blocks, kind,
			bindings, inlineHint, retention);
	}

	/**
	 * Where `fn` and the function its body decodes to first differ, or null when they are equal: every function the compiler makes
	 * must have a body (`IrVerifier.verifyReusing` with `CompileOptions.checkIrBody`).
	 */
	public static function roundTripDifference(fn:IrFunction, types:IrTypeIds):Null<String>
		return compiler.ir.codec.IrFunctionStateEquality.difference(fn, IrBodyBuilder.encode(fn, types).toFunction());

	function valueOf(id:Int, values:Array<Null<IrValue>>):IrValue {
		var value = values[id];
		if (value == null) {
			value = new IrValue(id, valueNames[id], types.type(valueTypes[id]));
			values[id] = value;
		}
		return value;
	}

	function operandValues(row:Int, from:Int, values:Array<Null<IrValue>>):Array<IrValue>
		return [for (index in operandStarts[row] + from...operandStarts[row + 1]) valueOf(operandPool[index], values)];

	function decodeInstruction(row:Int, values:Array<Null<IrValue>>):IrInstruction {
		var out = outputs[row] >= 0 ? valueOf(outputs[row], values) : null,
			aux = auxes[row];
		inline function at(index:Int):IrValue
			return valueOf(operand(row, index), values);
		return switch opcode(row) {
			case IrOpcode.Phi: Phi(out, [for (index in 0...operandCount(row))
				{
						block:ints[aux + index], value:at(index)
					}]);
			case IrOpcode.ConstVoid: ConstVoid(out);
			case IrOpcode.ConstInt: ConstInt(out, aux);
			case IrOpcode.ConstFloat: ConstFloat(out, floats[aux]);
			case IrOpcode.ConstString: ConstString(out, strings[aux]);
			case IrOpcode.StaticDataAddress: StaticDataAddress(out,
				[for (index in 0...ints[aux]) ints[aux + 1 + index]]);
			case IrOpcode.PointerOffset: PointerOffset(out, at(0), at(1));
			case IrOpcode.MemoryLoad: MemoryLoad(out, at(0), aux >> 1, aux & 1 == 1);
			case IrOpcode.MemoryStore: MemoryStore(at(0), at(1), aux);
			case IrOpcode.ConstBool: ConstBool(out, aux == 1);
			case IrOpcode.ConstNull: ConstNull(out);
			case IrOpcode.TypeValue: TypeValue(out, types.type(aux));
			case IrOpcode.ToDyn: ToDyn(out, at(0));
			case IrOpcode.IntToFloat: IntToFloat(out, at(0));
			case IrOpcode.IntToInt64: IntToInt64(out, at(0));
			case IrOpcode.FloatToInt: FloatToInt(out, at(0));
			case IrOpcode.FloatToFloat: FloatToFloat(out, at(0));
			case IrOpcode.SafeCast: SafeCast(out, at(0));
			case IrOpcode.BeginTry: BeginTry(ints[aux], ints[aux + 1], ints[aux + 2] == 1);
			case IrOpcode.EndTry: EndTry(ints[aux], ints[aux + 1] == 1);
			case IrOpcode.Catch: Catch(out);
			case IrOpcode.GlobalGet: GlobalGet(out, IrSymbol.at(aux).name);
			case IrOpcode.GlobalSet: GlobalSet(IrSymbol.at(aux).name, at(0));
			case IrOpcode.Add: Add(out, at(0), at(1));
			case IrOpcode.Sub: Sub(out, at(0), at(1));
			case IrOpcode.Mul: Mul(out, at(0), at(1));
			case IrOpcode.Div: Div(out, at(0), at(1));
			case IrOpcode.Mod: Mod(out, at(0), at(1));
			case IrOpcode.BitAnd: BitAnd(out, at(0), at(1));
			case IrOpcode.BitXor: BitXor(out, at(0), at(1));
			case IrOpcode.BitOr: BitOr(out, at(0), at(1));
			case IrOpcode.ShiftLeft: ShiftLeft(out, at(0), at(1));
			case IrOpcode.ShiftRight: ShiftRight(out, at(0), at(1));
			case IrOpcode.UnsignedShiftRight: UnsignedShiftRight(out, at(0), at(1));
			case IrOpcode.Less: Less(out, at(0), at(1));
			case IrOpcode.LessEqual: LessEqual(out, at(0), at(1));
			case IrOpcode.Equal: Equal(out, at(0), at(1));
			case IrOpcode.Call: Call(out, IrSymbol.at(aux), operandValues(row, 0, values));
			case IrOpcode.CNativeCall: CNativeCall(out, IrSymbol.at(aux).name, operandValues(row, 0, values));
			case IrOpcode.StaticClosure: StaticClosure(out, IrSymbol.at(aux));
			case IrOpcode.InstanceClosure: InstanceClosure(out, IrSymbol.at(aux), at(0));
			case IrOpcode.CallClosure: CallClosure(out, at(0), operandValues(row, 1, values));
			case IrOpcode.ToVirtual: ToVirtual(out, at(0));
			case IrOpcode.Upcast: Upcast(out, at(0));
			case IrOpcode.ClassId: ClassId(out, at(0));
			case IrOpcode.MethodCall: MethodCall(out, at(0), IrSymbol.at(aux >> 1).name, operandValues(row, 1, values),
				aux & 1 == 1);
			case IrOpcode.NewObject: NewObject(out, IrSymbol.at(aux).name);
			case IrOpcode.ValueInit: ValueInit(out);
			case IrOpcode.FieldGet: FieldGet(out, at(0), IrSymbol.at(aux).name);
			case IrOpcode.FieldSet: FieldSet(at(0), IrSymbol.at(aux).name, at(1));
			case IrOpcode.ArrayGet: ArrayGet(out, at(0), at(1));
			case IrOpcode.ArraySet: ArraySet(at(0), at(1), at(2));
			case IrOpcode.ArraySize: ArraySize(out, at(0));
			case IrOpcode.IteratorNew: IteratorNew(out, at(0));
			case IrOpcode.IteratorHasNext: IteratorHasNext(out, at(0));
			case IrOpcode.IteratorNext: IteratorNext(out, at(0));
			case IrOpcode.MakeEnum: MakeEnum(out, IrSymbol.at(ints[aux]).name, ints[aux + 1],
				operandValues(row, 0, values));
			case IrOpcode.EnumIndex: EnumIndex(out, at(0));
			case IrOpcode.EnumField: EnumField(out, at(0), ints[aux], ints[aux + 1]);
			case IrOpcode.EnumDynamicBox: Intrinsic(out, EnumDynamicBox(types.type(aux)),
				operandValues(row, 0, values));
			case IrOpcode.EnumDynamicView: Intrinsic(out, EnumDynamicView(types.type(aux)),
				operandValues(row, 0, values));
			case IrOpcode.EnumTagBox: Intrinsic(out, EnumTagBox(types.type(aux)), operandValues(row, 0, values));
			case IrOpcode.EnumTagUnbox: Intrinsic(out, EnumTagUnbox(types.type(aux)), operandValues(row, 0, values));
			case IrOpcode.InlineEnumBox: Intrinsic(out, InlineEnumBox(types.type(aux)), operandValues(row, 0, values));
			case IrOpcode.InlineEnumUnbox: Intrinsic(out, InlineEnumUnbox(types.type(aux)),
				operandValues(row, 0, values));
			default: throw new InternalError('IR body row $row is not an instruction');
		};
	}

	function decodeTerminator(row:Int, values:Array<Null<IrValue>>):IrTerminator {
		var aux = auxes[row];
		return switch opcode(row) {
			case IrOpcode.Unreachable: Unreachable;
			case IrOpcode.Return: Return(valueOf(operand(row, 0), values));
			case IrOpcode.Throw: Throw(valueOf(operand(row, 0), values));
			case IrOpcode.Rethrow: Rethrow(valueOf(operand(row, 0), values));
			case IrOpcode.Jump: Jump(aux);
			case IrOpcode.Branch: Branch(valueOf(operand(row, 0), values), ints[aux], ints[aux + 1]);
			case IrOpcode.Switch: Switch(valueOf(operand(row, 0), values),
				[for (index in 0...ints[aux + 1]) ints[aux + 2 + index]],
				ints[aux]);
			default: throw new InternalError('IR body row $row is not a terminator');
		};
	}
}
