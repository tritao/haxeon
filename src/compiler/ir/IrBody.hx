package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;

/**
 * A function body as a table (docs/design/IR_CORE_COLUMNS.md): one row per instruction or terminator in parallel `Int` columns
 * (opcode, output value or none, operand range in one operand pool, auxiliary field, provenance id, and the previous and next
 * row of its block), blocks as linked lists of rows in layout order, and values as `IrValueId`s with their name, type and defining
 * row in columns indexed by id.
 *
 * Passes edit a body in place. Rows never move: a removed row is unlinked, an added one appended and linked where it goes, and a
 * phi that gains inputs moves its runs to the end of the pools. So every walk follows the links (`firstRow`, `nextRow`), never a
 * range of row numbers. A body a cache holds is frozen (`freeze`): editing it is an internal error, and a pass that would change
 * it changes a copy (`thaw`).
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
	/** The `nextRow` of a row no block holds any more. */
	static inline final UNLINKED = -2;

	public final name:String;
	public final kind:IrFunctionKind;
	public final inlineHint:Bool;
	public final retention:IrRetention;

	/** The type id of the function's result. */
	public final result:Int;

	/** The program's type ids, which this body's type ids index. */
	public final types:IrTypeIds;

	/** Whether a cache may hold this body: then it is never edited again. */
	public var frozen(default, null) = false;

	/** Whether an edit left unlinked rows or garbage runs, which a compaction drops. */
	var edited = false;

	final opcodes:Array<Int>;
	final outputs:Array<Int>;
	final auxes:Array<Int>;
	final provenances:Array<Int>;
	final operandStarts:Array<Int>;
	final operandEnds:Array<Int>;
	final previousRows:Array<Int>;
	final nextRows:Array<Int>;
	final operandPool:Array<Int>;
	final ints:Array<Int>;
	final floats:Array<Float>;
	final strings:Array<String>;
	final provenancePool:Array<SourceProvenance>;
	final blockIds:Array<Int>;
	final blockFirstRows:Array<Int>;
	final blockLastRows:Array<Int>;
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

	/** By value id, the value that replaces it (`alias`), or -1; empty when the body has no alias. */
	final aliases:Array<Int> = [];

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
		operandEnds = builder.operandEnds.copy();
		previousRows = builder.previousRows.copy();
		nextRows = builder.nextRows.copy();
		operandPool = builder.operands.copy();
		ints = builder.ints.copy();
		floats = builder.floats.copy();
		strings = builder.strings.copy();
		provenancePool = builder.provenancePool.copy();
		blockIds = builder.blockIds.copy();
		blockFirstRows = builder.blockFirstRows.copy();
		blockLastRows = builder.blockLastRows.copy();
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

	/** Every row number is below it, linked or not: it sizes a table indexed by row. */
	public inline function rowLimit():Int
		return opcodes.length;

	public inline function opcode(row:Int):IrOpcode
		return opcodes[row];

	/** The value the row defines; one that does not `exist` when it defines none. */
	public inline function output(row:Int):IrValueId
		return IrValueId.of(outputs[row]);

	public inline function operandCount(row:Int):Int
		return operandEnds[row] - operandStarts[row];

	/** The row's operand `index`. */
	public inline function operand(row:Int, index:Int):IrValueId
		return IrValueId.of(operandPool[operandStarts[row] + index]);

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

	/** The row after `row` in its block, or -1 after the last. */
	public inline function nextRow(row:Int):Int
		return nextRows[row];

	/** The row before `row` in its block, or -1 before the first. */
	public inline function previousRow(row:Int):Int
		return previousRows[row];

	// Blocks, in layout order.

	public inline function blockCount():Int
		return blockIds.length;

	public inline function blockId(block:Int):Int
		return blockIds[block];

	/** The block's first row, or -1 when it has none. */
	public inline function firstRow(block:Int):Int
		return blockFirstRows[block];

	/** The block's last row, or -1 when it has none. */
	public inline function lastRow(block:Int):Int
		return blockLastRows[block];

	/** The block's terminator row, or -1 when it has none yet. */
	public function terminatorRow(block:Int):Int {
		var last = blockLastRows[block];
		return last >= 0 && opcode(last).isTerminator() ? last : -1;
	}

	/** The block's index in the layout, or -1 when it has no block with id `id`. */
	public function blockIndex(id:Int):Int {
		for (block in 0...blockIds.length)
			if (blockIds[block] == id)
				return block;
		return -1;
	}

	// Values.

	/** Every value id is below it: it sizes a table indexed by value. */
	public inline function valueLimit():Int
		return valueTypes.length;

	public inline function hasValue(value:IrValueId):Bool
		return (value:Int) < valueTypes.length && valueTypes[value] >= 0;

	public inline function valueTypeId(value:IrValueId):Int
		return valueTypes[value];

	public inline function valueType(value:IrValueId):IrType
		return types.type(valueTypes[value]);

	public inline function valueName(value:IrValueId):String
		return valueNames[value];

	/** The row defining the value, or -1 for an argument or a value no linked row defines. */
	public inline function definingRow(value:IrValueId):Int
		return valueRows[value];

	public inline function argumentCount():Int
		return argumentIds.length;

	public inline function argument(index:Int):IrValueId
		return IrValueId.of(argumentIds[index]);

	// Debug bindings.

	public inline function bindingCount():Int
		return bindingIdentities.length;

	public inline function bindingValue(index:Int):IrValueId
		return IrValueId.of(bindingValues[index]);

	// Ownership.

	/**
	 * This body, frozen, for a cache to hold: compacted first when an edit left garbage, so what is kept holds only what it
	 * reads.
	 */
	public function freeze(?builder:IrBodyBuilder):IrBody {
		var result = edited ? IrBodyBuilder.compact(this, builder) : this;
		result.frozen = true;
		return result;
	}

	/** A copy of this body that a pass may edit, compacted. */
	public function thaw(?builder:IrBodyBuilder):IrBody
		return IrBodyBuilder.compact(this, builder);

	// Edits, in place. Each requires the body not to be frozen.

	inline function editing():Void {
		if (frozen)
			throw new InternalError('IR body $name is frozen: a cache holds it, and a pass may only change a copy');
		edited = true;
	}

	/** Unlinks `row` from block `block` (an index); its output loses its defining row. */
	public function removeRow(block:Int, row:Int):Void {
		editing();
		var previous = previousRows[row], next = nextRows[row];
		if (previous >= 0)
			nextRows[previous] = next;
		else if (blockFirstRows[block] == row)
			blockFirstRows[block] = next;
		else
			throw new InternalError('IR body row $row is not in block ${blockIds[block]}');
		if (next >= 0)
			previousRows[next] = previous;
		else
			blockLastRows[block] = previous;
		previousRows[row] = UNLINKED;
		nextRows[row] = UNLINKED;
		var out = outputs[row];
		if (out >= 0 && valueRows[out] == row)
			valueRows[out] = -1;
	}

	/** Removes block `block` (an index) from the layout, and its rows from the body. */
	public function removeBlock(block:Int):Void {
		editing();
		var row = blockFirstRows[block];
		while (row >= 0) {
			var next = nextRows[row];
			var out = outputs[row];
			if (out >= 0 && valueRows[out] == row)
				valueRows[out] = -1;
			previousRows[row] = UNLINKED;
			nextRows[row] = UNLINKED;
			row = next;
		}
		blockIds.splice(block, 1);
		blockFirstRows.splice(block, 1);
		blockLastRows.splice(block, 1);
	}

	public function setAux(row:Int, value:Int):Void {
		editing();
		auxes[row] = value;
	}

	/** Sets entry `index` of the row's run in the int pool. */
	public function setAuxInt(row:Int, index:Int, value:Int):Void {
		editing();
		ints[auxes[row] + index] = value;
	}

	/** Removes input `index` of phi `row`, keeping the others in order. */
	public function removePhiInput(row:Int, index:Int):Void {
		editing();
		var start = operandStarts[row], end = operandEnds[row], aux = auxes[row];
		for (from in index + 1...end - start) {
			operandPool[start + from - 1] = operandPool[start + from];
			ints[aux + from - 1] = ints[aux + from];
		}
		operandEnds[row] = end - 1;
	}

	/** Adds an input to phi `row`, `value` from block `block`, after the others. */
	public function addPhiInput(row:Int, block:Int, value:IrValueId):Void {
		editing();
		var start = operandStarts[row], end = operandEnds[row], aux = auxes[row], count = end - start;
		// The runs grow where they are when both end their pools; otherwise they move to the ends.
		if (end != operandPool.length || aux + count != ints.length) {
			var newStart = operandPool.length, newAux = ints.length;
			for (index in 0...count) {
				operandPool.push(operandPool[start + index]);
				ints.push(ints[aux + index]);
			}
			operandStarts[row] = newStart;
			auxes[row] = newAux;
		}
		operandPool.push(value);
		ints.push(block);
		operandEnds[row] = operandPool.length;
	}

	/**
	 * Makes `replacement` stand for `value` in every row and binding that reads it. The reads change when the pass sweeps
	 * (`sweepAliases`), which it does before it returns; until then `resolve` gives what a read will become.
	 */
	public function alias(value:IrValueId, replacement:IrValueId):Void {
		editing();
		if (aliases.length < valueTypes.length) {
			var from = aliases.length;
			aliases.resize(valueTypes.length);
			for (index in from...valueTypes.length)
				aliases[index] = -1;
		}
		aliases[value] = replacement;
	}

	/** The value `value` stands for once the aliases are swept: itself, or the end of its chain of aliases. */
	public function resolve(value:IrValueId):IrValueId {
		var current:Int = value;
		while (current < aliases.length && aliases[current] >= 0)
			current = aliases[current];
		return IrValueId.of(current);
	}

	/** Rewrites every operand and binding that reads an aliased value to what it stands for, and forgets the aliases. */
	public function sweepAliases():Void {
		if (aliases.length == 0)
			return;
		for (index in 0...operandPool.length)
			operandPool[index] = resolve(IrValueId.of(operandPool[index]));
		for (index in 0...bindingValues.length)
			bindingValues[index] = resolve(IrValueId.of(bindingValues[index]));
		aliases.resize(0);
	}

	public function removeBinding(index:Int):Void {
		editing();
		bindingIdentities.splice(index, 1);
		bindingNames.splice(index, 1);
		bindingPaths.splice(index, 1);
		bindingStarts.splice(index, 1);
		bindingEnds.splice(index, 1);
		bindingValues.splice(index, 1);
	}

	/**
	 * Where this body's layout is broken, or null: each linked row is in one block and reached once, `previousRow` mirrors
	 * `nextRow`, a terminator only last, operand and int-pool runs inside their pools, a defining row for every linked output and
	 * none for an unlinked one, distinct block ids, no aliases left unswept.
	 */
	public function layoutDifference():Null<String> {
		if (aliases.length > 0)
			return 'aliases are left unswept';
		var seen:Array<Bool> = [];
		seen.resize(opcodes.length);
		var ids:Map<Int, Bool> = [];
		for (block in 0...blockIds.length) {
			var id = blockIds[block];
			if (ids.exists(id))
				return 'block $id appears twice';
			ids.set(id, true);
			var row = blockFirstRows[block], previous = -1;
			while (row >= 0) {
				if (row >= opcodes.length)
					return 'block $id links to row $row, past the rows';
				if (seen[row])
					return 'row $row is linked twice (block $id)';
				seen[row] = true;
				if (previousRows[row] != previous)
					return 'row $row of block $id has previous ${previousRows[row]}, not $previous';
				if (opcode(row).isTerminator() && nextRows[row] != -1)
					return 'terminator row $row of block $id is not last';
				if (operandStarts[row] < 0 || operandEnds[row] < operandStarts[row]
					|| operandEnds[row] > operandPool.length)
					return 'row $row has operands ${operandStarts[row]}...${operandEnds[row]} outside the pool';
				for (index in operandStarts[row]...operandEnds[row])
					if (operandPool[index] < 0 || operandPool[index] >= valueTypes.length
						|| valueTypes[operandPool[index]] < 0)
						return 'row $row reads value ${operandPool[index]}, which the body does not have';
				var out = outputs[row];
				if (out >= 0 && (out >= valueTypes.length || valueRows[out] != row))
					return 'row $row defines value $out, whose defining row is ${out < valueRows.length ? valueRows[out] : -1}';
				if (opcode(row) == IrOpcode.Phi && auxes[row] + operandCount(row) > ints.length)
					return 'phi row $row has predecessors outside the int pool';
				previous = row;
				row = nextRows[row];
			}
			if (blockLastRows[block] != previous)
				return 'block $id ends at row ${blockLastRows[block]}, not $previous';
		}
		for (value in 0...valueRows.length) {
			var row = valueRows[value];
			if (row >= 0 && (row >= opcodes.length || !seen[row] || outputs[row] != value))
				return 'value $value has defining row $row, which is not linked or defines another value';
		}
		return null;
	}

	/** The `IrFunction` this body is the table of, equal to the encoded one (`IrFunctionStateEquality.same`). */
	public function toFunction():IrFunction {
		var values:Array<Null<IrValue>> = [];
		values.resize(valueTypes.length);
		var blocks:Array<IrBlock> = [];
		for (block in 0...blockIds.length) {
			var instructions:Array<Located<IrInstruction>> = [],
				terminator = terminatorRow(block),
				row = blockFirstRows[block];
			while (row >= 0 && row != terminator) {
				instructions.push(new Located(decodeInstruction(row, values), provenance(row)));
				row = nextRows[row];
			}
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
	public static function roundTripDifference(fn:IrFunction, types:IrTypeIds):Null<String> {
		var body = IrBodyBuilder.encode(fn, types), layout = body.layoutDifference();
		if (layout != null)
			return 'layout: $layout';
		return compiler.ir.codec.IrFunctionStateEquality.difference(fn, body.toFunction());
	}

	function valueOf(id:Int, values:Array<Null<IrValue>>):IrValue {
		var value = values[id];
		if (value == null) {
			value = new IrValue(id, valueNames[id], types.type(valueTypes[id]));
			values[id] = value;
		}
		return value;
	}

	function operandValues(row:Int, from:Int, values:Array<Null<IrValue>>):Array<IrValue>
		return [for (index in operandStarts[row] + from...operandEnds[row]) valueOf(operandPool[index], values)];

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
