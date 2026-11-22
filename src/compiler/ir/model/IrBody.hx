package compiler.ir.model;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.IrFunction;
import compiler.ir.model.SourceProvenance;
import compiler.ir.model.SourceProvenance.Located;

/**
 * A function body as a table (docs/design/IR_CORE_COLUMNS.md): one row per instruction or terminator in parallel `Int` columns
 * (opcode, output value or none, operand range in one operand pool, auxiliary field, provenance id, and the previous and next
 * row of its block), blocks as linked lists of rows in layout order, and values as `IrValueId`s with their name, type and defining
 * row in columns indexed by id.
 *
 * Passes edit a body in place. Rows never move: a removed row is unlinked, an added one appended and linked where it goes, and a
 * phi that gains inputs moves its runs to the end of the pools. So every walk follows the links (`firstRow`, `nextRow`), never a
 * range of row numbers. A body a cache holds is frozen (`freeze`): editing it is an internal error, and a pass that would change
 * it changes a copy (`thaw`). One no cache holds is owned by the stage that has it, which edits it in place (`forEditing`).
 *
 * The auxiliary field by opcode: a constant (`ConstInt`, `ConstBool` 0 or 1, `MemoryStore` size, `MemoryLoad` size << 1 | signed,
 * `Jump` target); an index into the float or string pool (`ConstFloat`, `ConstString`); a type id (`TypeValue`, the intrinsics);
 * a symbol id (`Call`, `StaticClosure`, `InstanceClosure`, `CNativeCall`, `GlobalGet`, `GlobalSet`, `NewObject`, `FieldGet`,
 * `FieldSet`; `MethodCall` as symbol << 1 | terminal receiver); or the start of a run in the int pool: `Phi` one predecessor block
 * per operand, `StaticDataAddress` [count, bytes], `BeginTry` [catch, after, preserve], `EndTry` [catch, preserve], `MakeEnum`
 * [type symbol, constructor], `EnumField` [constructor, field], `Branch` [when true, when false], `Switch` [otherwise, count,
 * targets]. Operands are the instruction's values in the order `IrInstruction` declares them, the output left out.
 */
@:allow(compiler.ir.model.IrBodyBuilder)
class IrBody {
	/** The `nextRow` of a row no block holds any more. */
	static inline final UNLINKED = -2;

	public final name:String;
	public final kind:IrFunctionKind;
	public final inlineHint:Bool;
	public final retention:IrRetention;

	/** The type id of the function's result. */
	public var result(default, null):Int;

	/** The program's type ids, which this body's type ids index. */
	public final types:IrTypeIds;

	/** Whether a cache may hold this body: then it is never edited again. */
	public var frozen(default, null) = false;

	/**
	 * Whether an edit was made since the body was made (encoded, compacted, copied): one without is row for row what it was made
	 * from. An edit may leave unlinked rows or garbage runs, which a compaction drops.
	 */
	public var edited(default, null) = false;

	/** The edits made to this body, counted: a pass that edits a body in place compares the count to know whether it changed it. */
	public var edits(default, null) = 0;

	// The columns. A thawed copy of a body no edit touched shares its source's until its first edit (`sharing`).
	var opcodes:Array<Int>;
	var outputs:Array<Int>;
	var auxes:Array<Int>;
	var provenances:Array<Int>;
	var operandStarts:Array<Int>;
	var operandEnds:Array<Int>;
	var previousRows:Array<Int>;
	var nextRows:Array<Int>;
	var operandPool:Array<Int>;
	var ints:Array<Int>;
	var floats:Array<Float>;
	var strings:Array<String>;
	var provenancePool:Array<SourceProvenance>;
	var blockIds:Array<Int>;
	var blockFirstRows:Array<Int>;
	var blockLastRows:Array<Int>;
	var valueTypes:Array<Int>;
	var valueNames:Array<String>;
	var valueRows:Array<Int>;
	var argumentIds:Array<Int>;
	var bindingIdentities:Array<String>;
	var bindingNames:Array<String>;
	var bindingPaths:Array<String>;
	var bindingStarts:Array<Int>;
	var bindingEnds:Array<Int>;
	var bindingValues:Array<Int>;

	/** Whether the columns are a frozen body's, which the first edit copies (`unshare`): a thaw that is never edited copies nothing. */
	var sharing = false;

	/** Where the operands of the row being made (`beginRow`) start in the operand pool. */
	var rowOperandsFrom = 0;

	/** By value id, the value that replaces it (`alias`), or -1; empty when the body has no alias. */
	final aliases:Array<Int> = [];

	/** The trial open on this body (`beginTrial`), or null. */
	var trial:Null<IrBodyTrial> = null;

	/**
	 * Copies the builder's columns at their exact size; or, given a frozen body `shared`, takes its columns as they are but for a
	 * copy of the auxiliary column: frozen bodies are never edited, so they can share what they have in common.
	 */
	function new(builder:Null<IrBodyBuilder>, name:String, kind:IrFunctionKind, result:Int, inlineHint:Bool,
			retention:IrRetention, ?shared:IrBody) {
		this.name = name;
		this.kind = kind;
		this.result = result;
		this.inlineHint = inlineHint;
		this.retention = retention;
		if (shared != null) {
			types = shared.types;
			opcodes = shared.opcodes;
			outputs = shared.outputs;
			auxes = shared.auxes;
			provenances = shared.provenances;
			operandStarts = shared.operandStarts;
			operandEnds = shared.operandEnds;
			previousRows = shared.previousRows;
			nextRows = shared.nextRows;
			operandPool = shared.operandPool;
			ints = shared.ints;
			floats = shared.floats;
			strings = shared.strings;
			provenancePool = shared.provenancePool;
			blockIds = shared.blockIds;
			blockFirstRows = shared.blockFirstRows;
			blockLastRows = shared.blockLastRows;
			valueTypes = shared.valueTypes;
			valueNames = shared.valueNames;
			valueRows = shared.valueRows;
			argumentIds = shared.argumentIds;
			bindingIdentities = shared.bindingIdentities;
			bindingNames = shared.bindingNames;
			bindingPaths = shared.bindingPaths;
			bindingStarts = shared.bindingStarts;
			bindingEnds = shared.bindingEnds;
			bindingValues = shared.bindingValues;
		} else {
			if (builder == null)
				throw new InternalError('IR body $name has neither a builder nor a body to share');
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
	}

	/**
	 * This frozen body with auxiliary field `values[i]` in row `rows[i]`, frozen: it shares every other column with this one.
	 * For a field that stays meaningful for the row's opcode, a constant or a symbol id.
	 */
	public function withAuxes(rows:Array<Int>, values:Array<Int>):IrBody {
		if (!frozen)
			throw new InternalError('IR body $name is not frozen, so another body cannot share its columns');
		var result = new IrBody(null, name, kind, this.result, inlineHint, retention, this);
		result.auxes = auxes.copy();
		for (index in 0...rows.length)
			result.auxes[rows[index]] = values[index];
		result.frozen = true;
		return result;
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

	/** How many linked rows are instructions, terminators left out. */
	public function instructionCount():Int {
		var terminators = 0;
		for (block in 0...blockIds.length)
			if (terminatorRow(block) >= 0)
				terminators++;
		// A body no edit touched links every row it has.
		if (!edited)
			return opcodes.length - terminators;
		var rows = 0;
		for (block in 0...blockIds.length) {
			var row = blockFirstRows[block];
			while (row >= 0) {
				rows++;
				row = nextRows[row];
			}
		}
		return rows - terminators;
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

	public inline function bindingIdentity(index:Int):String
		return bindingIdentities[index];

	public inline function bindingName(index:Int):String
		return bindingNames[index];

	public inline function bindingPath(index:Int):String
		return bindingPaths[index];

	public inline function bindingScopeStart(index:Int):Int
		return bindingStarts[index];

	public inline function bindingScopeEnd(index:Int):Int
		return bindingEnds[index];

	// Ownership.

	/**
	 * This body, frozen, for holders that never edit it. Garbage left by edits costs only as long as the body lives: a body
	 * `retained` past this compile (a session's caches) is compacted first, so what a session keeps holds only what it reads;
	 * one the compile drops when it ends is frozen as it is.
	 */
	public function freeze(retained:Bool, ?builder:IrBodyBuilder):IrBody {
		var result = edited && retained ? IrBodyBuilder.compact(this, builder) : this;
		result.frozen = true;
		return result;
	}

	/** The body a pass edits for this one: this one when no cache holds it (it is not frozen), else a copy (`thaw`). */
	public inline function forEditing(?builder:IrBodyBuilder):IrBody
		return frozen ? thaw(builder) : this;

	/** A copy of this body that a pass may edit: compacted, or column for column when no edit left anything to drop. */
	public function thaw(?builder:IrBodyBuilder):IrBody {
		if (edited)
			return IrBodyBuilder.compact(this, builder);
		if (!frozen)
			return IrBodyBuilder.copy(this, builder);
		var result = new IrBody(null, name, kind, this.result, inlineHint, retention, this);
		result.sharing = true;
		return result;
	}

	// Edits, in place. Each requires the body not to be frozen.

	inline function editing():Void {
		if (frozen)
			throw new InternalError('IR body $name is frozen: a cache holds it, and a pass may only change a copy');
		if (sharing)
			unshare();
		edited = true;
		edits++;
	}

	/** Copies the columns this body shares with the frozen body it was thawed from, before its first edit. */
	function unshare():Void {
		sharing = false;
		opcodes = opcodes.copy();
		outputs = outputs.copy();
		auxes = auxes.copy();
		provenances = provenances.copy();
		operandStarts = operandStarts.copy();
		operandEnds = operandEnds.copy();
		previousRows = previousRows.copy();
		nextRows = nextRows.copy();
		operandPool = operandPool.copy();
		ints = ints.copy();
		floats = floats.copy();
		strings = strings.copy();
		provenancePool = provenancePool.copy();
		blockIds = blockIds.copy();
		blockFirstRows = blockFirstRows.copy();
		blockLastRows = blockLastRows.copy();
		valueTypes = valueTypes.copy();
		valueNames = valueNames.copy();
		valueRows = valueRows.copy();
		argumentIds = argumentIds.copy();
		bindingIdentities = bindingIdentities.copy();
		bindingNames = bindingNames.copy();
		bindingPaths = bindingPaths.copy();
		bindingStarts = bindingStarts.copy();
		bindingEnds = bindingEnds.copy();
		bindingValues = bindingValues.copy();
	}

	/** An edit that overwrites a pool entry or a binding, which a trial does not remember. */
	inline function overwriting():Void {
		editing();
		if (trial != null)
			throw new InternalError('IR body $name has a trial open, which could not undo this edit');
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
		overwriting();
		auxes[row] = value;
	}

	/**
	 * Makes `row` another operation, `opcode` with auxiliary field `aux`, keeping its output and operands: for an operation
	 * whose operands are the same values in the same order, and whose auxiliary field is no run in a pool.
	 */
	public function setOperation(row:Int, opcode:IrOpcode, aux:Int):Void {
		overwriting();
		opcodes[row] = opcode;
		auxes[row] = aux;
	}

	/** Sets entry `index` of the row's run in the int pool. */
	public function setAuxInt(row:Int, index:Int, value:Int):Void {
		overwriting();
		ints[auxes[row] + index] = value;
	}

	/** Removes input `index` of phi `row`, keeping the others in order. */
	public function removePhiInput(row:Int, index:Int):Void {
		overwriting();
		var start = operandStarts[row], end = operandEnds[row], aux = auxes[row];
		for (from in index + 1...end - start) {
			operandPool[start + from - 1] = operandPool[start + from];
			ints[aux + from - 1] = ints[aux + from];
		}
		operandEnds[row] = end - 1;
	}

	/** Adds an input to phi `row`, `value` from block `block`, after the others. */
	public function addPhiInput(row:Int, block:Int, value:IrValueId):Void {
		overwriting();
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

	/** Sets operand `index` of `row`. */
	public function setOperand(row:Int, index:Int, value:IrValueId):Void {
		overwriting();
		operandPool[operandStarts[row] + index] = value;
	}

	/** Gives value `value` the type with id `typeId`: for a pass that changes how a type is represented. */
	public function setValueType(value:IrValueId, typeId:Int):Void {
		overwriting();
		valueTypes[value] = typeId;
	}

	/** Gives the function the result type with id `typeId`. */
	public function setResult(typeId:Int):Void {
		overwriting();
		result = typeId;
	}

	/** A new value of this body, with the next id. */
	public function newValue(name:String, typeId:Int):IrValueId {
		editing();
		var id = valueTypes.length;
		valueTypes.push(typeId);
		valueNames.push(name);
		valueRows.push(-1);
		return IrValueId.of(id);
	}

	/** The id of `type` in this body's type table. */
	public inline function typeId(type:IrType):Int
		return types.id(type);

	/**
	 * Starts a row: its operands are the ones `pushOperand` appends until `endRow` makes it. Its auxiliary run, when it has one,
	 * starts where `pushInt` appends next.
	 */
	public function beginRow():Void {
		editing();
		rowOperandsFrom = operandPool.length;
	}

	public inline function pushOperand(value:IrValueId):Void {
		editing();
		operandPool.push(value);
	}

	/** Appends `value` to the int pool and gives its index. */
	public inline function pushInt(value:Int):Int {
		editing();
		ints.push(value);
		return ints.length - 1;
	}

	/** Adds a float to the pool and gives its index, for a `ConstFloat` row's auxiliary field. */
	public inline function addFloat(value:Float):Int {
		editing();
		floats.push(value);
		return floats.length - 1;
	}

	/** Adds a string to the pool and gives its index, for a `ConstString` row's auxiliary field. */
	public inline function addString(value:String):Int {
		editing();
		strings.push(value);
		return strings.length - 1;
	}

	/** Makes the row begun, unlinked: `linkBefore` or `linkAfter` puts it in a block. */
	public function endRow(opcode:IrOpcode, output:IrValueId, aux:Int, provenance:SourceProvenance):Int {
		var row = opcodes.length, last = provenancePool.length - 1;
		opcodes.push(opcode);
		outputs.push(output);
		auxes.push(aux);
		if (last < 0 || provenancePool[last] != provenance) {
			provenancePool.push(provenance);
			last++;
		}
		provenances.push(last);
		operandStarts.push(rowOperandsFrom);
		operandEnds.push(operandPool.length);
		previousRows.push(UNLINKED);
		nextRows.push(UNLINKED);
		rowOperandsFrom = operandPool.length;
		return row;
	}

	/**
	 * Makes a copy of `source`'s row `row` here, unlinked: each operand and the output renamed through `values` (by source
	 * value id; -1 keeps the id), each block it names through `blocks` when given, its pool entries copied.
	 */
	public function copyRow(source:IrBody, row:Int, values:Array<Int>, ?blocks:Array<Int>):Int {
		beginRow();
		for (index in source.operandStarts[row]...source.operandEnds[row])
			operandPool.push(renamed(source.operandPool[index], values));
		var aux = source.auxes[row], opcode = source.opcode(row);
		var copied = switch opcode {
			case IrOpcode.ConstFloat: addFloat(source.floats[aux]);
			case IrOpcode.ConstString: addString(source.strings[aux]);
			case IrOpcode.StaticDataAddress: copyInts(source, aux, 1 + source.ints[aux]);
			case IrOpcode.MakeEnum, IrOpcode.EnumField: copyInts(source, aux, 2);
			case IrOpcode.Phi:
				var start = ints.length;
				for (index in 0...source.operandCount(row))
					ints.push(renamedBlock(source.ints[aux + index], blocks));
				start;
			case IrOpcode.BeginTry:
				var start = pushInt(renamedBlock(source.ints[aux], blocks));
				ints.push(renamedBlock(source.ints[aux + 1], blocks));
				ints.push(source.ints[aux + 2]);
				start;
			case IrOpcode.EndTry:
				var start = pushInt(renamedBlock(source.ints[aux], blocks));
				ints.push(source.ints[aux + 1]);
				start;
			case IrOpcode.Jump: renamedBlock(aux, blocks);
			case IrOpcode.Branch:
				var start = pushInt(renamedBlock(source.ints[aux], blocks));
				ints.push(renamedBlock(source.ints[aux + 1], blocks));
				start;
			case IrOpcode.Switch:
				var start = pushInt(renamedBlock(source.ints[aux], blocks)), count = source.ints[aux + 1];
				ints.push(count);
				for (index in 0...count)
					ints.push(renamedBlock(source.ints[aux + 2 + index], blocks));
				start;
			default: aux;
		};
		var out = source.outputs[row];
		return endRow(opcode, IrValueId.of(out >= 0 ? renamed(out, values) : -1), copied, source.provenance(row));
	}

	static inline function renamed(id:Int, values:Array<Int>):Int
		return id >= 0 && id < values.length && values[id] >= 0 ? values[id] : id;

	static inline function renamedBlock(id:Int, blocks:Null<Array<Int>>):Int
		return blocks == null ? id : blocks[id];

	function copyInts(source:IrBody, start:Int, count:Int):Int {
		var result = ints.length;
		for (index in start...start + count)
			ints.push(source.ints[index]);
		return result;
	}

	/** Links `row`, made by `endRow` or `copyRow`, into block `block` (an index) after `after`, or first when `after` is -1. */
	public function linkAfter(block:Int, after:Int, row:Int):Void {
		editing();
		var next = after >= 0 ? nextRows[after] : blockFirstRows[block];
		previousRows[row] = after;
		nextRows[row] = next;
		if (after >= 0)
			nextRows[after] = row;
		else
			blockFirstRows[block] = row;
		if (next >= 0)
			previousRows[next] = row;
		else
			blockLastRows[block] = row;
		var out = outputs[row];
		if (out >= 0)
			valueRows[out] = row;
	}

	/** Links `row` into block `block` (an index) before `before`, or last when `before` is -1. */
	public inline function linkBefore(block:Int, before:Int, row:Int):Void
		linkAfter(block, before >= 0 ? previousRows[before] : blockLastRows[block], row);

	/** Adds an empty block with id `id` to the layout at index `at`. */
	public function addBlock(at:Int, id:Int):Void {
		editing();
		blockIds.insert(at, id);
		blockFirstRows.insert(at, -1);
		blockLastRows.insert(at, -1);
	}

	/** Moves `row` and every row after it in block `from` (an index) to the end of block `to`. */
	public function moveTail(from:Int, row:Int, to:Int):Void {
		editing();
		var previous = previousRows[row], last = blockLastRows[from];
		if (previous >= 0)
			nextRows[previous] = -1;
		else
			blockFirstRows[from] = -1;
		blockLastRows[from] = previous;
		var tail = blockLastRows[to];
		previousRows[row] = tail;
		if (tail >= 0)
			nextRows[tail] = row;
		else
			blockFirstRows[to] = row;
		blockLastRows[to] = last;
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
		overwriting();
		for (index in 0...operandPool.length)
			operandPool[index] = resolve(IrValueId.of(operandPool[index]));
		for (index in 0...bindingValues.length)
			bindingValues[index] = resolve(IrValueId.of(bindingValues[index]));
		aliases.resize(0);
	}

	/**
	 * Opens a trial: until `endTrial`, `rollback` brings the body back to this point. Within it rows and values may be made,
	 * linked and unlinked, blocks added, removed and split, and aliases set; an edit that overwrites a pool entry or a binding
	 * is an internal error. For a pass that only knows whether a change pays once it has made it.
	 */
	public function beginTrial(into:IrBodyTrial):Void {
		// What the body was before the trial: `editing` below marks it edited.
		into.edits = edits;
		into.edited = edited;
		editing();
		if (trial != null)
			throw new InternalError('IR body $name has a trial open already');
		trial = into;
		into.rows = opcodes.length;
		into.operands = operandPool.length;
		into.ints = ints.length;
		into.floats = floats.length;
		into.strings = strings.length;
		into.provenances = provenancePool.length;
		into.values = valueTypes.length;
		IrBodyTrial.save(into.previousRows, previousRows);
		IrBodyTrial.save(into.nextRows, nextRows);
		IrBodyTrial.save(into.blockIds, blockIds);
		IrBodyTrial.save(into.blockFirstRows, blockFirstRows);
		IrBodyTrial.save(into.blockLastRows, blockLastRows);
		IrBodyTrial.save(into.valueRows, valueRows);
		IrBodyTrial.save(into.aliases, aliases);
	}

	/** Keeps what the open trial did. */
	public function endTrial():Void {
		if (trial == null)
			throw new InternalError('IR body $name has no trial open');
		trial = null;
	}

	/** Undoes what the open trial did, and ends it. */
	public function rollback():Void {
		var saved = trial;
		if (saved == null)
			throw new InternalError('IR body $name has no trial open');
		trial = null;
		var rows = saved.rows;
		opcodes.resize(rows);
		outputs.resize(rows);
		auxes.resize(rows);
		provenances.resize(rows);
		operandStarts.resize(rows);
		operandEnds.resize(rows);
		operandPool.resize(saved.operands);
		ints.resize(saved.ints);
		floats.resize(saved.floats);
		strings.resize(saved.strings);
		provenancePool.resize(saved.provenances);
		valueTypes.resize(saved.values);
		valueNames.resize(saved.values);
		IrBodyTrial.save(previousRows, saved.previousRows);
		IrBodyTrial.save(nextRows, saved.nextRows);
		IrBodyTrial.save(blockIds, saved.blockIds);
		IrBodyTrial.save(blockFirstRows, saved.blockFirstRows);
		IrBodyTrial.save(blockLastRows, saved.blockLastRows);
		IrBodyTrial.save(valueRows, saved.valueRows);
		IrBodyTrial.save(aliases, saved.aliases);
		rowOperandsFrom = operandPool.length;
		edited = saved.edited;
		edits = saved.edits;
	}

	public function removeBinding(index:Int):Void {
		overwriting();
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
		var arguments = [for (id in argumentIds) valueOf(id, values)];
		return new IrFunction(name, arguments, types.type(result), decodeBlocks(values), kind, decodeBindings(values),
			inlineHint, retention);
	}

	/** The arguments of the function this body is (`IrFunction.ofBody`), which `decodeRest` decodes the rest with. */
	public function decodeArguments():Array<IrValue>
		return [for (id in argumentIds) new IrValue(id, valueNames[id], types.type(valueTypes[id]))];

	/** The blocks and bindings of the function this body is, given its arguments as `decodeArguments` made them. */
	public function decodeRest(arguments:Array<IrValue>):{blocks:Array<IrBlock>, bindings:Array<IrDebugBinding>} {
		var values:Array<Null<IrValue>> = [];
		values.resize(valueTypes.length);
		for (argument in arguments)
			values[argument.id] = argument;
		return {blocks: decodeBlocks(values), bindings: decodeBindings(values)};
	}

	function decodeBlocks(values:Array<Null<IrValue>>):Array<IrBlock> {
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
		return blocks;
	}

	function decodeBindings(values:Array<Null<IrValue>>):Array<IrDebugBinding>
		return [for (index in 0...bindingIdentities.length)
			{
				identity:bindingIdentities[index],
					name:bindingNames[index],
					value:valueOf(bindingValues[index], values),
					path:bindingPaths[index],
					scopeStart:bindingStarts[index],
					scopeEnd:bindingEnds[index]
			}];

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

/**
 * What `IrBody.beginTrial` remembers of a body for `rollback`: the sizes of its columns, and copies of the ones that edits
 * change in place.
 */
@:allow(compiler.ir.model.IrBody)
class IrBodyTrial {
	var edited = false;
	var edits = 0;
	var rows = 0;
	var operands = 0;
	var ints = 0;
	var floats = 0;
	var strings = 0;
	var provenances = 0;
	var values = 0;
	final previousRows:Array<Int> = [];
	final nextRows:Array<Int> = [];
	final blockIds:Array<Int> = [];
	final blockFirstRows:Array<Int> = [];
	final blockLastRows:Array<Int> = [];
	final valueRows:Array<Int> = [];
	final aliases:Array<Int> = [];

	public function new() {}

	/** Makes `into` a copy of `from`, in its own storage. */
	static function save(into:Array<Int>, from:Array<Int>):Void {
		into.resize(from.length);
		for (index in 0...from.length)
			into[index] = from[index];
	}
}
