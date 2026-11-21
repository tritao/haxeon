package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance.Located;

private typedef KnownField = {
	final object:Int;
	final field:String;
	final value:IrValue;
}

/** An array element whose value is known: `index` is a constant when `constant`, else the id of the index value. */
private typedef KnownElement = {
	final array:IrValue;
	final constant:Bool;
	final index:Int;
	final value:IrValue;
}

/** Cross-block field and block-local array reload elimination. Stores and the input function are never changed.
 * Runtime array-cast checks enforce concrete storage types; differently typed arrays cannot alias
 * the same elements. Erased dynamic array accesses use calls, which invalidate all known loads. */
class IrLoadStoreForwarding {

	/**
	 * Object layouts are needed only to exclude inline value fields; unknown Obj fields are excluded too. `scratch`, when given,
	 * lends the graph.
	 */
	public static function run(fn:IrFunction, ?objects:IrObjectTable, ?scratch:IrPassScratch):IrFunction {
		var pass = scratch ?? new IrPassScratch(), tables = pass.loadStore;
		var result = forward(fn, objects, pass, tables);
		tables.release();
		return result;
	}

	/**
	 * `run` on a body, in place: a forwarded load is unlinked and its output made an alias of the value it was forwarded from;
	 * whether any was.
	 */
	public static function runBody(body:IrBody, objects:Null<IrObjectTable>, scratch:IrPassScratch):Bool
		return IrBodyLoadStoreForwarding.run(body, objects, scratch);

	static function forward(fn:IrFunction, objects:Null<IrObjectTable>, pass:IrPassScratch,
			tables:IrLoadStoreScratch):IrFunction {
		var substitutes = tables.substitutes, constants = tables.constants, constantValues = tables.constantValues;
		constants.clear();
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case ConstInt(out, value):
						constants.add(out.id);
						while (constantValues.length <= out.id)
							constantValues.push(0);
						constantValues[out.id] = value;
					default:
				}
		function constant(value:IrValue):Null<Int>
			return constants.has(value.id) ? constantValues[value.id] : null;
		var use = function(value:IrValue):IrValue {
			while (value.id < substitutes.length && substitutes[value.id] != null)
				value = substitutes[value.id];
			return value;
		};
		var renamed = function(value:IrValue):Bool return value.id < substitutes.length
			&& substitutes[value.id] != null;
		var sameBlock = function(id:Int):Int return id;
		function substitute(out:IrValue, known:IrValue):Void {
			while (substitutes.length <= out.id)
				substitutes.push(null);
			substitutes[out.id] = known;
		}
		// Nothing is copied until a load is forwarded: most functions forward nothing, and a copy of every block that is then thrown away
		// (with a remapped instruction for each analyzed one) was most of this pass's allocation.
		incomingFields(fn, objects, pass, tables);
		var dropped:Null<haxe.ds.ObjectMap<Dynamic, Bool>> = null,
			substituted = 0;
		// A block's facts start from its incoming fields; the field and element facts each reuse one list.
		var fields = tables.fields, elements = tables.elements;
		for (block in fn.blocks) {
			fields.resize(0);
			if (block.id < tables.incomingCount.length) {
				var start = tables.incomingStart[block.id];
				for (index in start...start + tables.incomingCount[block.id]) {
					var key = tables.incomingKeys[index];
					fields.push({
						object: tables.keyObjects[key],
						field: tables.keyFields[key],
						value: tables.incomingValues[index]
					});
				}
			}
			elements.resize(0);
			for (located in block.instructions) {
				var instruction = substituted == 0
					|| !IrOperands.anyValue(located.value, renamed) ? located.value : IrInliner.remap(located.value,
					use,
					sameBlock),
					drop = false;
				switch instruction {
					case FieldSet(object, field, value):
						if (excludedField(value.type, objects) || !plainObject(object.type)) {
							// An inline struct store can overwrite fields reached through earlier interior pointers.
							fields.resize(0);
							elements.resize(0);
						} else {
							dropFieldName(fields, field);
							if (!storeNeedsNormalization(object.type, field, objects))
								fields.push({object: object.id, field: field, value: value});
						}
					case FieldGet(out, object, field):
						if (!plainObject(object.type)) {
							fields.resize(0);
							elements.resize(0);
						} else if (!excludedField(out.type, objects)) {
							var known:Null<IrValue> = null;
							for (entry in fields)
								if (entry.object == object.id && entry.field == field)
									known = entry.value;
							if (known != null && sameType(out.type, known.type)) {
								substitute(out, known);
								substituted++;
								drop = true;
							} else {
								dropField(fields, object.id, field);
								fields.push({object: object.id, field: field, value: out});
							}
						}
					case ArraySet(array, index, value):
						if (!plainArray(array.type) || excludedField(value.type, objects)) {
							fields.resize(0);
							elements.resize(0);
						} else {
							var literal = constant(index),
								constant = literal != null,
								key = literal == null ? index.id : literal;
							dropAliasedElements(elements, array, constant, key);
							elements.push({
								array: array,
								constant: constant,
								index: key,
								value: value
							});
						}
					case ArrayGet(out, array, index):
						if (!plainArray(array.type)) {
							fields.resize(0);
							elements.resize(0);
						} else if (!excludedField(out.type, objects)) {
							var literal = constant(index),
								constant = literal != null,
								key = literal == null ? index.id : literal,
								known:Null<IrValue> = null;
							for (entry in elements)
								if (entry.array.id == array.id && entry.constant == constant && entry.index == key)
									known = entry.value;
							if (known != null && sameType(out.type, known.type)) {
								substitute(out, known);
								substituted++;
								drop = true;
							} else {
								dropElement(elements, array.id, constant, key);
								elements.push({
									array: array,
									constant: constant,
									index: key,
									value: out
								});
							}
						}
					default:
						if (mayWriteMemory(instruction)) {
							fields.resize(0);
							elements.resize(0);
						}
				}
				if (drop) {
					if (dropped == null)
						dropped = new haxe.ds.ObjectMap();
					dropped.set(located, true);
				}
			}
		}
		if (substituted == 0)
			return fn;
		// Every use of a forwarded load's output takes the value it was forwarded from, in any block (successor phis, debug
		// bindings): the blocks with a dropped load or such a use are copied, the others are shared as they are.
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var changed = false;
			for (located in block.instructions)
				if ((dropped != null && dropped.exists(located)) || IrOperands.anyValue(located.value, renamed)) {
					changed = true;
					break;
				}
			var term = block.terminator,
				terminator:Null<IrTerminator> = term == null ? null : switch term.value {
					case Unreachable, Jump(_): null;
					case Return(value): renamed(value) ? Return(use(value)) : null;
					case Throw(value): renamed(value) ? Throw(use(value)) : null;
					case Rethrow(value): renamed(value) ? Rethrow(use(value)) : null;
					case Branch(condition, yes, no): renamed(condition) ? Branch(use(condition), yes, no) : null;
					case Switch(switchValue, switchTargets, switchOtherwise): renamed(switchValue)
						? Switch(use(switchValue),
						switchTargets.copy(), switchOtherwise) : null;
				};
			if (!changed && terminator == null) {
				blocks.push(block);
				continue;
			}
			var copy = new IrBlock(block.id);
			for (located in block.instructions)
				if (dropped == null || !dropped.exists(located))
					copy.instructions.push(IrOperands.anyValue(located.value, renamed)
						? new Located(IrInliner.remap(located.value,
						use, sameBlock), located.provenance) : located);
			copy.terminator = term == null || terminator == null ? term : new Located(terminator, term.provenance);
			blocks.push(copy);
		}
		var bindings:Array<IrDebugBinding> = [for (binding in fn.debugBindings)
			renamed(binding.value) ? {
				identity: binding.identity,
				name: binding.name,
				value: use(binding.value),
				path: binding.path,
				scopeStart: binding.scopeStart,
				scopeEnd: binding.scopeEnd
			} : binding];
		return fn.withBlocks(blocks, bindings);
	}

	/**
	 * Fields available on every normal path into each block, as `tables`' incoming rows: per block id, a run of keys (see
	 * `keyObjects` and `keyFields`) with their values. A block past the rows, or with an empty run, has none.
	 */
	static function incomingFields(fn:IrFunction, objects:Null<IrObjectTable>, pass:IrPassScratch,
			tables:IrLoadStoreScratch):Void {
		var keyObjects = tables.keyObjects,
			keyFields = tables.keyFields,
			byObject:Map<Int, Map<String, Int>> = [],
			byField:Map<String, Array<Int>> = [],
			repeated = false;
		tables.incomingCount.resize(0);
		keyObjects.resize(0);
		keyFields.resize(0);
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case BeginTry(_, _, _), EndTry(_, _), Catch(_):
						return;
					case FieldGet(_, object, field), FieldSet(object, field, _) if (plainObject(object.type)):
						var fields = byObject.get(object.id);
						if (fields == null) {
							fields = [];
							byObject.set(object.id, fields);
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
							keyObjects.push(object.id);
							keyFields.push(field);
						}
					default:
				}
		if (!repeated || fn.blocks.length < 2)
			return;
		// A key's state is absent (not available), present with a null value (the analysis top), or present with its value.
		var count = keyObjects.length,
			graph = pass.graph.reset(fn),
			blockCount = 0;
		for (block in fn.blocks)
			if (block.id >= blockCount)
				blockCount = block.id + 1;
		var outgoing = tables.outgoingFields(blockCount);
		for (id in graph.order)
			outgoing[id].setEverything();
		var before = tables.before.reset(count),
			after = tables.after.reset(count),
			entry = fn.blocks[0].id;
		function meet(id:Int, into:FieldStates):Void {
			var count = graph.predecessorCount(id);
			if (id == entry || count == 0) {
				into.clear();
				return;
			}
			into.load(outgoing[graph.predecessor(id, 0)]);
			for (i in 1...count)
				into.intersect(outgoing[graph.predecessor(id, i)]);
		}
		// A block with an instruction that forgets every field leaves with what the instructions after the last such one give, whatever
		// it was entered with: its state is made once, from nothing, and only the other blocks meet their predecessors.
		var resumeAt = IrPassScratch.filledInts(tables.resumeAt, blockCount, 0), settled = tables.settled;
		settled.clear();
		for (id in graph.order) {
			var instructions = graph.block(id).instructions, resume = 0;
			for (index in 0...instructions.length)
				if (forgetsFields(instructions[index].value, objects))
					resume = index + 1;
			resumeAt[id] = resume;
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (id in graph.order) {
				var instructions = graph.block(id).instructions, resume = resumeAt[id];
				if (resume > 0) {
					if (!settled.add(id))
						continue;
					after.clear();
				} else
					meet(id, after);
				for (index in resume...instructions.length)
					switch instructions[index].value {
						case FieldSet(_, field, _):
							var sameName = byField.get(field);
							if (sameName != null)
								for (key in sameName)
									after.present[key] = false;
						case FieldGet(out, object, field) if (!excludedField(out.type, objects)):
							// Every field access of a plain object was given a key above.
							var fields = byObject.get(object.id),
								found = fields == null ? null : fields.get(field),
								key = found == null ? throw new InternalError('No field key for $field') : found;
							if (!after.present[key]) {
								after.present[key] = true;
								after.values[key] = out;
							}
						default:
					}
				if (!after.matches(outgoing[id])) {
					after.storeInto(outgoing[id]);
					changed = true;
				}
			}
		}
		// With the outgoing states fixed, each block's incoming state is the meet of its predecessors' once more.
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
				if (before.present[key] && value != null) {
					keys.push(key);
					values.push(value);
				}
			}
			counts[id] = keys.length - starts[id];
		}
		graph.release();
	}

	/** Whether `instruction` makes every available field unknown: an access the keys do not cover, a call or a memory write. */
	static function forgetsFields(instruction:IrInstruction, objects:Null<IrObjectTable>):Bool
		return switch instruction {
			case FieldSet(object, _, value): excludedField(value.type, objects) || !plainObject(object.type);
			case FieldGet(_, object, _): !plainObject(object.type);
			case ArraySet(array, _, value): !plainArray(array.type) || excludedField(value.type, objects);
			case ArrayGet(_, array, _): !plainArray(array.type);
			// Across blocks, even a non-writing call is an explicit barrier.
			case Call(_, _, _): true;
			default: mayWriteMemory(instruction);
		};

	static inline function sameType(a:IrType, b:IrType):Bool
		return IrTypeIdentity.same(a, b);

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

	// The fact lists are filtered in place, keeping their order.

	static function dropFieldName(fields:Array<KnownField>, field:String):Void {
		var kept = 0;
		for (entry in fields)
			if (entry.field != field)
				fields[kept++] = entry;
		fields.resize(kept);
	}

	static function dropField(fields:Array<KnownField>, object:Int, field:String):Void {
		var kept = 0;
		for (entry in fields)
			if (entry.object != object || entry.field != field)
				fields[kept++] = entry;
		fields.resize(kept);
	}

	/** After a store to `array[key]`: keeps the same array's elements at other constant indices and arrays of other types. */
	static function dropAliasedElements(elements:Array<KnownElement>, array:IrValue, constant:Bool, key:Int):Void {
		var kept = 0;
		for (entry in elements)
			if (entry.array.id == array.id ? constant && entry.constant
				&& entry.index != key : !sameType(entry.array.type, array.type))
				elements[kept++] = entry;
		elements.resize(kept);
	}

	static function dropElement(elements:Array<KnownElement>, array:Int, constant:Bool, key:Int):Void {
		var kept = 0;
		for (entry in elements)
			if (entry.array.id != array || entry.constant != constant || entry.index != key)
				elements[kept++] = entry;
		elements.resize(kept);
	}

	/** Unknown operations kill all facts. Dynamic arithmetic/comparisons can dispatch user code. */
	public static function mayWriteMemory(instruction:IrInstruction):Bool
		return switch instruction {
			case Call(_, name,
				_) if (name.name == IrReceiverCheck.NAME || name.name == IrReferenceIdentity.NAME): false;
			case Phi(_, _), ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstString(_, _), ConstBool(_, _),
				ConstNull(_), TypeValue(_, _),
				StaticDataAddress(_, _), PointerOffset(_, _, _), MemoryLoad(_, _, _, _), NewObject(_, _), ValueInit(_),
				IntToFloat(_, _), IntToInt64(_, _),
				FloatToInt(_, _), FloatToFloat(_, _), ArraySize(_, _), EnumIndex(_, _), EnumField(_, _, _, _): false;
			case Add(_, a, b), Sub(_, a, b), Mul(_, a, b), Div(_, a, b), Mod(_, a, b), BitAnd(_, a, b), BitOr(_, a, b),
				BitXor(_, a, b), ShiftLeft(_, a, b),
				ShiftRight(_, a, b), UnsignedShiftRight(_, a, b), Less(_, a, b), LessEqual(_, a, b),
				Equal(_, a, b): !primitive(a.type) || !primitive(b.type);
			default: true;
		};

	static function primitive(type:IrType):Bool
		return switch type {
			case I32, I64, F32, F64, Bool: true;
			default: false;
		};
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

	/** `IrLoadStoreForwarding.incomingFields` on a body; keys are (object value id, field symbol id). */
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

	/** `IrLoadStoreForwarding.mayWriteMemory` for a row; operands resolved through the aliases when `resolved`. */
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

/** `BlockFields` with value ids, -1 for the analysis top. */
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

/** `FieldStates` with value ids, -1 for the analysis top. */
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
@:allow(compiler.ir.IrBodyLoadStoreForwarding)
class IrBodyLoadStoreScratch {
	final constants = new IrPassScratch.IrValueMarks();
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
	final settled = new IrPassScratch.IrValueMarks();
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

/**
 * A block's outgoing available fields, stored compactly: the present keys and their values (null for the analysis top), or
 * every key with the top value, the state every block starts from. Each block has its own, refilled as the analysis goes.
 */
private class BlockFields {
	public var everything = true;

	public final keys:Array<Int> = [];
	public final values:Array<Null<IrValue>> = [];

	public function new() {}

	public function setEverything():Void {
		everything = true;
		keys.resize(0);
		values.resize(0);
	}

	/** Lets go of the values. */
	public function release():Void {
		for (index in 0...values.length)
			values[index] = null;
		values.resize(0);
		keys.resize(0);
	}
}

/**
 * The available-field state being computed at one program point, one slot per field key of the function: a key is absent,
 * present with a null value (the analysis top), or present with its value. A function keeps only a few of these.
 */
private class FieldStates {
	public final present:Array<Bool>;
	public final values:Array<Null<IrValue>>;

	// The keys of the state being intersected in, marked with the current generation.
	final marks:Array<Int>;
	final marked:Array<Null<IrValue>>;
	var generation = 0;

	public function new() {
		present = [];
		values = [];
		marks = [];
		marked = [];
	}

	/** Makes this a state of `count` keys, each absent, in the storage of the last function's. */
	public function reset(count:Int):FieldStates {
		IrPassScratch.filledBools(present, count, false);
		IrPassScratch.filledInts(marks, count, 0);
		values.resize(0);
		marked.resize(0);
		for (_ in 0...count) {
			values.push(null);
			marked.push(null);
		}
		return this;
	}

	/** Lets go of the values. */
	public function release():Void {
		for (index in 0...values.length) {
			values[index] = null;
			marked[index] = null;
		}
	}

	public function clear():Void
		for (key in 0...present.length)
			present[key] = false;

	public function load(fields:Null<BlockFields>):Void {
		if (fields != null && fields.everything) {
			for (key in 0...present.length) {
				present[key] = true;
				values[key] = null;
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

	/** Keeps the keys present in both; a top takes the other side's value, and differing values make the key absent. */
	public function intersect(fields:Null<BlockFields>):Void {
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
			if (mine == null)
				values[key] = theirs;
			else if (theirs != null && !sameValue(mine, theirs))
				present[key] = false;
		}
	}

	public function copyFrom(other:FieldStates):Void
		for (key in 0...present.length) {
			present[key] = other.present[key];
			values[key] = other.values[key];
		}

	public function matches(fields:BlockFields):Bool {
		if (fields.everything) {
			for (key in 0...present.length)
				if (!present[key] || values[key] != null)
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
			var key = fields.keys[index],
				mine = values[key],
				theirs = fields.values[index];
			if (!present[key] || (mine == null ? theirs != null : theirs == null || !sameValue(mine, theirs)))
				return false;
		}
		return true;
	}

	/** Writes this state, compactly, as `fields`. */
	public function storeInto(fields:BlockFields):Void {
		fields.everything = false;
		fields.keys.resize(0);
		fields.values.resize(0);
		for (key in 0...present.length)
			if (present[key]) {
				fields.keys.push(key);
				fields.values.push(values[key]);
			}
	}

	static inline function sameValue(a:IrValue, b:IrValue):Bool
		return a.id == b.id && IrTypeIdentity.same(a.type, b.type);
}

/**
 * The tables of `IrLoadStoreForwarding`, kept from one function to the next (`IrPassScratch.loadStore`); `release` drops
 * every value of the function, so none stays reachable from them.
 */
@:allow(compiler.ir.IrLoadStoreForwarding)
class IrLoadStoreScratch {
	/** Per value id: what a forwarded load is replaced by, and the value of an integer constant. */
	final substitutes:Array<Null<IrValue>> = [];

	final constants = new IrPassScratch.IrValueMarks();
	final constantValues:Array<Int> = [];

	/** The facts of the block being rewritten. */
	final fields:Array<KnownField> = [];

	final elements:Array<KnownElement> = [];

	/** The function's field keys: the object value id and the field name of each. */
	final keyObjects:Array<Int> = [];

	final keyFields:Array<String> = [];

	/** The incoming fields: per block id, where its run starts in `incomingKeys`/`incomingValues` and how long it is. */
	final incomingStart:Array<Int> = [];

	final incomingCount:Array<Int> = [];
	final incomingKeys:Array<Int> = [];
	final incomingValues:Array<IrValue> = [];

	/** Per block id: its outgoing fields, the instruction its state is made from, and whether that state is made. */
	final outgoing:Array<BlockFields> = [];

	var outgoingUsed = 0;
	final resumeAt:Array<Int> = [];
	final settled = new IrPassScratch.IrValueMarks();
	final before = new FieldStates();
	final after = new FieldStates();

	public function new() {}

	/** The outgoing fields of `count` block ids, kept from the last function. */
	function outgoingFields(count:Int):Array<BlockFields> {
		while (outgoing.length < count)
			outgoing.push(new BlockFields());
		if (count > outgoingUsed)
			outgoingUsed = count;
		return outgoing;
	}

	function release():Void {
		for (index in 0...substitutes.length)
			substitutes[index] = null;
		substitutes.resize(0);
		for (index in 0...fields.length)
			fields[index] = null;
		fields.resize(0);
		for (index in 0...elements.length)
			elements[index] = null;
		elements.resize(0);
		for (index in 0...incomingValues.length)
			incomingValues[index] = null;
		incomingValues.resize(0);
		for (index in 0...outgoingUsed)
			outgoing[index].release();
		outgoingUsed = 0;
		before.release();
		after.release();
	}
}
