package compiler.ir.passes.cleanup;

import compiler.ir.model.IrPassScratch.IrValueMarks;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFieldStorage;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.names.IrReceiverCheck;
import compiler.ir.names.IrReferenceIdentity;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrValueId;
import compiler.core.InternalError;
import compiler.ir.model.Ir;

/**
 * Cross-block field and block-local array reload elimination, on a body in place. Stores are never changed.
 * Runtime array-cast checks enforce concrete storage types; differently typed arrays cannot alias
 * the same elements. Erased dynamic array accesses use calls, which invalidate all known loads.
 * Object layouts are needed only to exclude inline value fields; unknown Obj fields are excluded too.
 */
class IrLoadStoreForwarding {
	/**
	 * A forwarded load is unlinked and its output made an alias of the value it was forwarded from;
	 * whether any was.
	 */
	public static function runBody(body:IrBody, objects:Null<IrObjectTable>, scratch:IrPassScratch):Bool
		return IrBodyLoadStoreForwarding.run(body, objects, scratch);

	/** A native-width store may change its input before a later load observes it. */
	public static function storeNeedsNormalization(type:IrType, field:String, objects:Null<IrObjectTable>):Bool {
		if (objects == null)
			return false;
		var name:Null<String> = switch type {
			case Obj(value): value;
			default: null;
		};
		while (name != null) {
			var object = objects.get(name);
			if (object == null)
				return false;
			for (entry in object.fields)
				if (entry.name == field) {
					// A Float32 field rounds even when its enclosing object has no native layout.
					if (Type.enumEq(entry.type, F32))
						return true;
					var native = IrFieldStorage.scalar(entry);
					if (native == null)
						return false;
					return switch entry.type {
						case I32: native.size > 0 && native.size < 4;
						case I64: native.size > 0 && native.size < 8;
						default: false;
					};
				}
			name = object.base;
		}
		return false;
	}

}

/** `IrLoadStoreForwarding.runBody`: the facts are value ids, field names symbol ids. */
private class IrBodyLoadStoreForwarding {
	public static function run(body:IrBody, objects:Null<IrObjectTable>, scratch:IrPassScratch):Bool {
		var tables = scratch.bodyLoadStore, constants = tables.constants, constantValues = tables.constantValues;
		constants.clear();
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.ConstInt) {
					var out:Int = body.output(row);
					constants.add(out);
					while (constantValues.length <= out)
						constantValues.push(0);
					constantValues[out] = body.aux(row);
				}
				row = body.nextRow(row);
			}
		}
		incomingFields(body, objects, scratch, tables);
		var checkSymbol = IrSymbol.of(IrReceiverCheck.NAME).id,
			identitySymbol = IrSymbol.of(IrReferenceIdentity.NAME).id;
		var fieldObjects = tables.fieldObjects, fieldNames = tables.fieldNames, fieldValues = tables.fieldValues;
		var elementArrays = tables.elementArrays,
			elementConstant = tables.elementConstant,
			elementIndices = tables.elementIndices,
			elementValues = tables.elementValues;
		var forwarded = false;
		for (block in 0...body.blockCount()) {
			tables.forgetAll();
			var id = body.blockId(block);
			if (id < tables.incomingCount.length) {
				var start = tables.incomingStart[id];
				for (index in start...start + tables.incomingCount[id]) {
					var key = tables.incomingKeys[index];
					tables.pushField(tables.keyObjects[key], tables.keyFields[key], tables.incomingValues[index]);
				}
			}
			var row = body.firstRow(block);
			while (row >= 0) {
				var next = body.nextRow(row);
				switch body.opcode(row) {
					case IrOpcode.FieldSet:
						var object = body.resolve(body.operand(row, 0)),
							value = body.resolve(body.operand(row, 1)),
							field = body.aux(row);
						if (excludedField(body.valueType(value), objects) || !plainObject(body.valueType(object)))
							// An inline struct store can overwrite fields reached through earlier interior pointers.
							tables.forgetAll();
						else {
							tables.dropFields(-1, field);
							if (!IrLoadStoreForwarding.storeNeedsNormalization(body.valueType(object),
								IrSymbol.at(field).name,
								objects))
								tables.pushField(object, field, value);
						}
					case IrOpcode.FieldGet:
						var out = body.output(row), object = body.resolve(body.operand(row, 0)), field = body.aux(row);
						if (!plainObject(body.valueType(object)))
							tables.forgetAll();
						else if (!excludedField(body.valueType(out), objects)) {
							var known = -1;
							for (index in 0...fieldObjects.length)
								if (fieldObjects[index] == object && fieldNames[index] == field)
									known = fieldValues[index];
							if (known >= 0 && body.valueTypeId(out) == body.valueTypeId(IrValueId.of(known))) {
								body.alias(out, IrValueId.of(known));
								body.removeRow(block, row);
								forwarded = true;
							} else {
								tables.dropFields(object, field);
								tables.pushField(object, field, out);
							}
						}
					case IrOpcode.ArraySet:
						var array = body.resolve(body.operand(row, 0)),
							index = body.resolve(body.operand(row, 1)),
							value = body.resolve(body.operand(row, 2));
						if (!plainArray(body.valueType(array)) || excludedField(body.valueType(value), objects))
							tables.forgetAll();
						else {
							var constant = constants.has(index),
								key = constant ? constantValues[index] : (index:Int),
								arrayType = body.valueTypeId(array);
							tables.dropAliasedElements(body, array, constant, key, arrayType);
							tables.pushElement(array, constant, key, value);
						}
					case IrOpcode.ArrayGet:
						var out = body.output(row),
							array = body.resolve(body.operand(row, 0)),
							index = body.resolve(body.operand(row, 1));
						if (!plainArray(body.valueType(array)))
							tables.forgetAll();
						else if (!excludedField(body.valueType(out), objects)) {
							var constant = constants.has(index),
								key = constant ? constantValues[index] : (index:Int),
								known = -1;
							for (entry in 0...elementArrays.length)
								if (elementArrays[entry] == array && elementConstant[entry] == constant
									&& elementIndices[entry] == key)
									known = elementValues[entry];
							if (known >= 0 && body.valueTypeId(out) == body.valueTypeId(IrValueId.of(known))) {
								body.alias(out, IrValueId.of(known));
								body.removeRow(block, row);
								forwarded = true;
							} else {
								tables.dropElement(array, constant, key);
								tables.pushElement(array, constant, key, out);
							}
						}
					default:
						if (mayWriteMemory(body, row, checkSymbol, identitySymbol, true))
							tables.forgetAll();
				}
				row = next;
			}
		}
		if (forwarded)
			body.sweepAliases();
		return forwarded;
	}

	/**
	 * Fields available on every normal path into each block, as `tables`' incoming rows: per block id, a run of keys (object
	 * value id, field symbol id; see `keyObjects` and `keyFields`) with their values. A block past the rows, or with an empty run,
	 * has none.
	 */
	static function incomingFields(body:IrBody, objects:Null<IrObjectTable>, pass:IrPassScratch,
			tables:IrBodyLoadStoreScratch):Void {
		var keyObjects = tables.keyObjects,
			keyFields = tables.keyFields,
			byObject:Map<Int, Map<Int, Int>> = [],
			byField:Map<Int, Array<Int>> = [],
			repeated = false;
		tables.incomingCount.resize(0);
		keyObjects.resize(0);
		keyFields.resize(0);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.BeginTry, IrOpcode.EndTry, IrOpcode.Catch:
						return;
					case IrOpcode.FieldGet, IrOpcode.FieldSet if (plainObject(body.valueType(body.operand(row, 0)))):
						var object:Int = body.operand(row, 0), field = body.aux(row);
						var fields = byObject.get(object);
						if (fields == null) {
							fields = [];
							byObject.set(object, fields);
						}
						if (fields.exists(field))
							repeated = true;
						else {
							fields.set(field, keyObjects.length);
							var sameName = byField.get(field);
							if (sameName == null) {
								sameName = [];
								byField.set(field, sameName);
							}
							sameName.push(keyObjects.length);
							keyObjects.push(object);
							keyFields.push(field);
						}
					default:
				}
				row = body.nextRow(row);
			}
		}
		if (!repeated || body.blockCount() < 2)
			return;
		var count = keyObjects.length,
			graph = pass.bodyGraph.reset(body),
			blockCount = 0;
		for (block in 0...body.blockCount())
			if (body.blockId(block) >= blockCount)
				blockCount = body.blockId(block) + 1;
		var outgoing = tables.outgoingFields(blockCount);
		for (id in graph.order)
			outgoing[id].setEverything();
		var before = tables.before.reset(count),
			after = tables.after.reset(count),
			entry = body.blockId(0);
		function meet(id:Int, into:BodyFieldStates):Void {
			var count = graph.predecessorCount(id);
			if (id == entry || count == 0) {
				into.clear();
				return;
			}
			into.load(outgoing[graph.predecessor(id, 0)]);
			for (i in 1...count)
				into.intersect(outgoing[graph.predecessor(id, i)]);
		}
		var checkSymbol = IrSymbol.of(IrReceiverCheck.NAME).id,
			identitySymbol = IrSymbol.of(IrReferenceIdentity.NAME).id;
		// A block with a row that forgets every field leaves with what the rows after the last such one give: its state is made
		// once, from nothing. `resumeAt` is that row's successor, or -2 for a block that meets its predecessors.
		var resumeAt = IrPassScratch.filledInts(tables.resumeAt, blockCount, -2), settled = tables.settled;
		settled.clear();
		for (id in graph.order) {
			var block = graph.indexOf(id), row = body.firstRow(block);
			while (row >= 0) {
				if (forgetsFields(body, row, objects, checkSymbol, identitySymbol))
					resumeAt[id] = body.nextRow(row);
				row = body.nextRow(row);
			}
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (id in graph.order) {
				var block = graph.indexOf(id), resume = resumeAt[id], row = body.firstRow(block);
				if (resume != -2) {
					if (!settled.add(id))
						continue;
					after.clear();
					row = resume;
				} else
					meet(id, after);
				while (row >= 0) {
					switch body.opcode(row) {
						case IrOpcode.FieldSet:
							var sameName = byField.get(body.aux(row));
							if (sameName != null)
								for (key in sameName)
									after.present[key] = false;
						case IrOpcode.FieldGet if (!excludedField(body.valueType(body.output(row)), objects)):
							var fields = byObject.get(body.operand(row, 0)),
								found = fields == null ? null : fields.get(body.aux(row)),
								key = found == null
									? throw new InternalError('No field key for ${IrSymbol.at(body.aux(row)).name}')
									: found;
							if (!after.present[key]) {
								after.present[key] = true;
								after.values[key] = body.output(row);
							}
						default:
					}
					row = body.nextRow(row);
				}
				if (!after.matches(outgoing[id])) {
					after.storeInto(outgoing[id]);
					changed = true;
				}
			}
		}
		var starts = IrPassScratch.filledInts(tables.incomingStart, blockCount, 0),
			counts = IrPassScratch.filledInts(tables.incomingCount, blockCount, 0),
			keys = tables.incomingKeys,
			values = tables.incomingValues;
		keys.resize(0);
		values.resize(0);
		for (id in graph.order) {
			meet(id, before);
			starts[id] = keys.length;
			for (key in 0...count) {
				var value = before.values[key];
				if (before.present[key] && value >= 0) {
					keys.push(key);
					values.push(value);
				}
			}
			counts[id] = keys.length - starts[id];
		}
	}

	static function forgetsFields(body:IrBody, row:Int, objects:Null<IrObjectTable>, checkSymbol:Int,
			identitySymbol:Int):Bool
		return switch body.opcode(row) {
			case IrOpcode.FieldSet: excludedField(body.valueType(body.operand(row, 1)), objects)
				|| !plainObject(body.valueType(body.operand(row, 0)));
			case IrOpcode.FieldGet: !plainObject(body.valueType(body.operand(row, 0)));
			case IrOpcode.ArraySet: !plainArray(body.valueType(body.operand(row, 0)))
				|| excludedField(body.valueType(body.operand(row, 2)), objects);
			case IrOpcode.ArrayGet: !plainArray(body.valueType(body.operand(row, 0)));
			// Across blocks, even a non-writing call is an explicit barrier.
			case IrOpcode.Call: true;
			// A terminator is no instruction: it forgets nothing.
			case opcode if (opcode.isTerminator()): false;
			default: mayWriteMemory(body, row, checkSymbol, identitySymbol, false);
		};

	/**
	 * Unknown operations kill all facts. Dynamic arithmetic/comparisons can dispatch user code. Operands are resolved through the
	 * aliases when `resolved`.
	 */
	static function mayWriteMemory(body:IrBody, row:Int, checkSymbol:Int, identitySymbol:Int, resolved:Bool):Bool
		return switch body.opcode(row) {
			case IrOpcode.Call: body.aux(row) != checkSymbol && body.aux(row) != identitySymbol;
			case IrOpcode.Phi, IrOpcode.ConstVoid, IrOpcode.ConstInt, IrOpcode.ConstFloat, IrOpcode.ConstString,
				IrOpcode.ConstBool, IrOpcode.ConstNull, IrOpcode.TypeValue, IrOpcode.StaticDataAddress,
				IrOpcode.PointerOffset,
				IrOpcode.MemoryLoad, IrOpcode.NewObject, IrOpcode.ValueInit, IrOpcode.IntToFloat, IrOpcode.IntToInt64,
				IrOpcode.FloatToInt, IrOpcode.FloatToFloat, IrOpcode.ArraySize, IrOpcode.EnumIndex,
				IrOpcode.EnumField: false;
			case IrOpcode.Add, IrOpcode.Sub, IrOpcode.Mul, IrOpcode.Div, IrOpcode.Mod, IrOpcode.BitAnd, IrOpcode.BitOr,
				IrOpcode.BitXor, IrOpcode.ShiftLeft, IrOpcode.ShiftRight, IrOpcode.UnsignedShiftRight, IrOpcode.Less,
				IrOpcode.LessEqual, IrOpcode.Equal: !primitiveOperand(body, row, 0, resolved)
				|| !primitiveOperand(body, row, 1, resolved);
			// A terminator ends the block's facts' walk; it writes nothing the walk could still see.
			case opcode if (opcode.isTerminator()): false;
			default: true;
		};

	static function primitiveOperand(body:IrBody, row:Int, index:Int, resolved:Bool):Bool {
		var value = body.operand(row, index);
		return primitive(body.valueType(resolved ? body.resolve(value) : value));
	}

	static function primitive(type:IrType):Bool
		return switch type {
			case I32, I64, F32, F64, Bool: true;
			default: false;
		};

	static function plainObject(type:IrType):Bool
		return switch type {
			case Obj(_): true;
			default: false;
		};

	static function plainArray(type:IrType):Bool
		return switch type {
			case Array(_): true;
			default: false;
		};

	static function excludedField(type:IrType, objects:Null<IrObjectTable>):Bool
		return switch type {
			case Obj(name): var descriptor = objects == null ? null : objects.get(name);
				descriptor == null || descriptor.isValue;
			default: false;
		};
}

/**
 * A block's outgoing available fields, stored compactly: the present keys and their values (-1 for the analysis top), or every
 * key with the top value, the state every block starts from. Each block has its own, refilled as the analysis goes.
 */
private class BodyBlockFields {
	public var everything = true;

	public final keys:Array<Int> = [];
	public final values:Array<Int> = [];

	public function new() {}

	public function setEverything():Void {
		everything = true;
		keys.resize(0);
		values.resize(0);
	}
}

/**
 * The available-field state being computed at one program point, one slot per field key of the function: a key is absent,
 * present with -1 (the analysis top), or present with its value id. A function keeps only a few of these.
 */
private class BodyFieldStates {
	public final present:Array<Bool> = [];
	public final values:Array<Int> = [];

	final marks:Array<Int> = [];
	final marked:Array<Int> = [];
	var generation = 0;

	public function new() {}

	public function reset(count:Int):BodyFieldStates {
		IrPassScratch.filledBools(present, count, false);
		IrPassScratch.filledInts(marks, count, 0);
		IrPassScratch.filledInts(values, count, -1);
		IrPassScratch.filledInts(marked, count, -1);
		return this;
	}

	public function clear():Void
		for (key in 0...present.length)
			present[key] = false;

	public function load(fields:Null<BodyBlockFields>):Void {
		if (fields != null && fields.everything) {
			for (key in 0...present.length) {
				present[key] = true;
				values[key] = -1;
			}
			return;
		}
		clear();
		if (fields != null)
			for (index in 0...fields.keys.length) {
				var key = fields.keys[index];
				present[key] = true;
				values[key] = fields.values[index];
			}
	}

	public function intersect(fields:Null<BodyBlockFields>):Void {
		if (fields != null && fields.everything)
			return;
		generation++;
		if (fields != null)
			for (index in 0...fields.keys.length) {
				var key = fields.keys[index];
				marks[key] = generation;
				marked[key] = fields.values[index];
			}
		for (key in 0...present.length) {
			if (!present[key])
				continue;
			if (marks[key] != generation) {
				present[key] = false;
				continue;
			}
			var mine = values[key], theirs = marked[key];
			if (mine < 0)
				values[key] = theirs;
			else if (theirs >= 0 && mine != theirs)
				present[key] = false;
		}
	}

	public function matches(fields:BodyBlockFields):Bool {
		if (fields.everything) {
			for (key in 0...present.length)
				if (!present[key] || values[key] >= 0)
					return false;
			return true;
		}
		var count = 0;
		for (key in 0...present.length)
			if (present[key])
				count++;
		if (count != fields.keys.length)
			return false;
		for (index in 0...fields.keys.length) {
			var key = fields.keys[index], mine = values[key], theirs = fields.values[index];
			if (!present[key] || mine != theirs)
				return false;
		}
		return true;
	}

	public function storeInto(fields:BodyBlockFields):Void {
		fields.everything = false;
		fields.keys.resize(0);
		fields.values.resize(0);
		for (key in 0...present.length)
			if (present[key]) {
				fields.keys.push(key);
				fields.values.push(values[key]);
			}
	}
}

/** The tables of `IrBodyLoadStoreForwarding`, kept from one function to the next (`IrPassScratch.bodyLoadStore`). */
@:allow(compiler.ir.passes.cleanup.IrBodyLoadStoreForwarding)
class IrBodyLoadStoreScratch {
	final constants = new IrValueMarks();
	final constantValues:Array<Int> = [];
	final fieldObjects:Array<Int> = [];
	final fieldNames:Array<Int> = [];
	final fieldValues:Array<Int> = [];
	final elementArrays:Array<Int> = [];
	final elementConstant:Array<Bool> = [];
	final elementIndices:Array<Int> = [];
	final elementValues:Array<Int> = [];
	final keyObjects:Array<Int> = [];
	final keyFields:Array<Int> = [];
	final incomingStart:Array<Int> = [];
	final incomingCount:Array<Int> = [];
	final incomingKeys:Array<Int> = [];
	final incomingValues:Array<Int> = [];
	final outgoing:Array<BodyBlockFields> = [];
	final resumeAt:Array<Int> = [];
	final settled = new IrValueMarks();
	final before = new BodyFieldStates();
	final after = new BodyFieldStates();

	public function new() {}

	function forgetAll():Void {
		fieldObjects.resize(0);
		fieldNames.resize(0);
		fieldValues.resize(0);
		resizeElements(0);
	}

	inline function pushField(object:Int, field:Int, value:Int):Void {
		fieldObjects.push(object);
		fieldNames.push(field);
		fieldValues.push(value);
	}

	inline function pushElement(array:Int, constant:Bool, index:Int, value:Int):Void {
		elementArrays.push(array);
		elementConstant.push(constant);
		elementIndices.push(index);
		elementValues.push(value);
	}

	/** Drops the facts about `field` of `object`, or of every object when `object` is -1, keeping the others in order. */
	function dropFields(object:Int, field:Int):Void {
		var kept = 0;
		for (index in 0...fieldObjects.length)
			if (fieldNames[index] != field || object >= 0 && fieldObjects[index] != object) {
				fieldObjects[kept] = fieldObjects[index];
				fieldNames[kept] = fieldNames[index];
				fieldValues[kept] = fieldValues[index];
				kept++;
			}
		fieldObjects.resize(kept);
		fieldNames.resize(kept);
		fieldValues.resize(kept);
	}

	/** After a store to `array[key]`: keeps the same array's elements at other constant indices and arrays of other types. */
	function dropAliasedElements(body:IrBody, array:Int, constant:Bool, key:Int, arrayType:Int):Void {
		var kept = 0;
		for (index in 0...elementArrays.length)
			if (elementArrays[index] == array ? constant && elementConstant[index]
				&& elementIndices[index] != key : body.valueTypeId(IrValueId.of(elementArrays[index])) != arrayType)
				keepElement(index, kept++);
		resizeElements(kept);
	}

	function dropElement(array:Int, constant:Bool, key:Int):Void {
		var kept = 0;
		for (index in 0...elementArrays.length)
			if (elementArrays[index] != array || elementConstant[index] != constant || elementIndices[index] != key)
				keepElement(index, kept++);
		resizeElements(kept);
	}

	inline function keepElement(from:Int, to:Int):Void {
		elementArrays[to] = elementArrays[from];
		elementConstant[to] = elementConstant[from];
		elementIndices[to] = elementIndices[from];
		elementValues[to] = elementValues[from];
	}

	inline function resizeElements(count:Int):Void {
		elementArrays.resize(count);
		elementConstant.resize(count);
		elementIndices.resize(count);
		elementValues.resize(count);
	}

	function outgoingFields(count:Int):Array<BodyBlockFields> {
		while (outgoing.length < count)
			outgoing.push(new BodyBlockFields());
		return outgoing;
	}
}
