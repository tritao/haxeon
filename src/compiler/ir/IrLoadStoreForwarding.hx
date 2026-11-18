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

	/** Object layouts are needed only to exclude inline value fields; unknown Obj fields are excluded too. */
	public static function run(fn:IrFunction, ?objects:IrObjectTable):IrFunction {
		var substitutions:Map<Int, IrValue> = [], constants:Map<Int, Int> = [];
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case ConstInt(out, value):
						constants.set(out.id, value);
					default:
				}
		var use = function(value:IrValue):IrValue {
			while (substitutions.exists(value.id))
				value = substitutions.get(value.id);
			return value;
		};
		// Nothing is copied until a load is forwarded: most functions forward nothing, and a copy of every block that is then thrown away
		// (with a remapped instruction for each analyzed one) was most of this pass's allocation.
		var incoming = incomingFields(fn, objects),
			dropped:Null<haxe.ds.ObjectMap<Dynamic, Bool>> = null,
			substituted = 0;
		// Each block's incoming fields are its own to change; the element facts reuse one list.
		var elements:Array<KnownElement> = [];
		for (block in fn.blocks) {
			var fields:Array<KnownField> = incoming.exists(block.id) ? incoming.get(block.id) : [];
			elements.resize(0);
			for (located in block.instructions) {
				var instruction = substituted == 0 ? located.value : IrInliner.remap(located.value, use,
					function(id:Int):Int return id),
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
								substitutions.set(out.id, known);
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
							var literal = constants.get(index.id),
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
							var literal = constants.get(index.id),
								constant = literal != null,
								key = literal == null ? index.id : literal,
								known:Null<IrValue> = null;
							for (entry in elements)
								if (entry.array.id == array.id && entry.constant == constant && entry.index == key)
									known = entry.value;
							if (known != null && sameType(out.type, known.type)) {
								substitutions.set(out.id, known);
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
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions)
				if (dropped == null || !dropped.exists(located))
					copy.instructions.push(located);
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		// Rewrite the whole function: successor phis and debug bindings may use deleted outputs.
		for (block in blocks) {
			for (index in 0...block.instructions.length) {
				var located = block.instructions[index];
				block.instructions[index] = new Located(IrInliner.remap(located.value, use,
					function(id:Int):Int return id), located.provenance);
			}
			var term = block.terminator;
			if (term != null)
				block.terminator = new Located(switch term.value {
					case Unreachable: Unreachable;
					case Return(value): Return(use(value));
					case Throw(value): Throw(use(value));
					case Rethrow(value): Rethrow(use(value));
					case Branch(condition, yes, no): Branch(use(condition), yes, no);
					case Switch(switchValue, switchTargets, switchOtherwise): Switch(use(switchValue),
						switchTargets.copy(), switchOtherwise);
					case Jump(target): Jump(target);
				}, term.provenance);
		}
		var bindings:Array<IrDebugBinding> = [for (binding in fn.debugBindings)
			{
				identity:binding.identity,
					name:binding.name,
					value:use(binding.value),
					path:binding.path,
					scopeStart:binding.scopeStart,
					scopeEnd:binding.scopeEnd
			}];
		return fn.withBlocks(blocks, bindings);
	}

	/** Fields available on every normal path into each block. */
	static function incomingFields(fn:IrFunction, objects:Null<IrObjectTable>):Map<Int, Array<KnownField>> {
		var result:Map<Int, Array<KnownField>> = [],
			keyObjects:Array<Int> = [],
			keyFields:Array<String> = [],
			byObject:Map<Int, Map<String, Int>> = [],
			byField:Map<String, Array<Int>> = [],
			repeated = false;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case BeginTry(_, _, _), EndTry(_, _), Catch(_):
						return result;
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
			return result;
		// A key's state is absent (not available), present with a null value (the analysis top), or present with its value.
		var count = keyObjects.length,
			graph = new IrGraph(fn),
			outgoing:Map<Int, BlockFields> = [],
			top = BlockFields.top();
		for (id in graph.order)
			outgoing.set(id, top);
		var before = new FieldStates(count),
			after = new FieldStates(count),
			entry = fn.blocks[0].id;
		function meet(id:Int, into:FieldStates):Void {
			var predecessors = graph.predecessorsOf(id);
			if (id == entry || predecessors.length == 0) {
				into.clear();
				return;
			}
			into.load(outgoing.get(predecessors[0]));
			for (i in 1...predecessors.length)
				into.intersect(outgoing.get(predecessors[i]));
		}
		// A block with an instruction that forgets every field leaves with what the instructions after the last such one give, whatever
		// it was entered with: its state is made once, from nothing, and only the other blocks meet their predecessors.
		var resumeAt:Map<Int, Int> = [], settled:Map<Int, Bool> = [];
		for (id in graph.order) {
			var instructions = graph.block(id).instructions, resume = 0;
			for (index in 0...instructions.length)
				if (forgetsFields(instructions[index].value, objects))
					resume = index + 1;
			resumeAt.set(id, resume);
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (id in graph.order) {
				var instructions = graph.block(id).instructions, resume = resumeAt.get(id);
				if (resume > 0) {
					if (settled.exists(id))
						continue;
					settled.set(id, true);
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
				if (!after.matches(outgoing.get(id))) {
					outgoing.set(id, after.compact());
					changed = true;
				}
			}
		}
		// With the outgoing states fixed, each block's incoming state is the meet of its predecessors' once more.
		for (id in graph.order) {
			meet(id, before);
			var fields:Array<KnownField> = [];
			for (key in 0...count) {
				var value = before.values[key];
				if (before.present[key] && value != null)
					fields.push({object: keyObjects[key], field: keyFields[key], value: value});
			}
			result.set(id, fields);
		}
		return result;
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
	static function storeNeedsNormalization(type:IrType, field:String, objects:Null<IrObjectTable>):Bool {
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

/** A block's outgoing available fields, stored compactly: the present keys and their values (null for the analysis top). */
private class BlockFields {
	/** Every key present with the top value: the state every block starts from. */
	public final everything:Bool;

	public final keys:Array<Int>;
	public final values:Array<Null<IrValue>>;

	public function new(everything:Bool, keys:Array<Int>, values:Array<Null<IrValue>>) {
		this.everything = everything;
		this.keys = keys;
		this.values = values;
	}

	public static function top():BlockFields
		return new BlockFields(true, [], []);
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

	public function new(count:Int) {
		present = [];
		values = [];
		marks = [];
		marked = [];
		for (_ in 0...count) {
			present.push(false);
			values.push(null);
			marks.push(0);
			marked.push(null);
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

	public function compact():BlockFields {
		var keys:Array<Int> = [], kept:Array<Null<IrValue>> = [];
		for (key in 0...present.length)
			if (present[key]) {
				keys.push(key);
				kept.push(values[key]);
			}
		return new BlockFields(false, keys, kept);
	}

	static inline function sameValue(a:IrValue, b:IrValue):Bool
		return a.id == b.id && IrTypeIdentity.same(a.type, b.type);
}
