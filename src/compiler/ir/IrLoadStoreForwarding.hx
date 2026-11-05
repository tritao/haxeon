package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance.Located;

private typedef KnownField = {final object:Int; final field:String; final value:IrValue;}
private typedef AvailableField = {final object:Int; final field:String; final value:Null<IrValue>;}
private typedef KnownElement = {final array:IrValue; final index:String; final value:IrValue;}

/** Cross-block field and block-local array reload elimination. Stores and the input function are never changed.
 * Runtime array-cast checks enforce concrete storage types; differently typed arrays cannot alias
 * the same elements. Erased dynamic array accesses use calls, which invalidate all known loads. */
class IrLoadStoreForwarding {
	public static var enabled:Bool = Sys.getEnv("HAXEON_LOADSTORE") != "0";

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
		var incoming = incomingFields(fn, objects), blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var fields:Array<KnownField> = incoming.exists(block.id) ? incoming.get(block.id).copy() : [],
				elements:Array<KnownElement> = [];
			var copy = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = IrInliner.remap(located.value, use, function(id:Int):Int return id), drop = false;
				switch instruction {
					case FieldSet(object, field, value):
						if (excludedField(value.type, objects) || !plainObject(object.type)) {
							// An inline struct store can overwrite fields reached through earlier interior pointers.
							fields = [];
							elements = [];
						} else {
							fields = [for (entry in fields) if (entry.field != field) entry];
							if (!storeNeedsNormalization(object.type, field, objects))
								fields.push({object: object.id, field: field, value: value});
						}
					case FieldGet(out, object, field):
						if (!plainObject(object.type)) {
							fields = [];
							elements = [];
						} else if (!excludedField(out.type, objects)) {
							var known:Null<IrValue> = null;
							for (entry in fields)
								if (entry.object == object.id && entry.field == field)
									known = entry.value;
							if (known != null && sameType(out.type, known.type)) {
								substitutions.set(out.id, known);
								drop = true;
							} else {
								fields = [
									for (entry in fields)
										if (entry.object != object.id || entry.field != field) entry
								];
								fields.push({object: object.id, field: field, value: out});
							}
						}
					case ArraySet(array, index, value):
						if (!plainArray(array.type) || excludedField(value.type, objects)) {
							fields = [];
							elements = [];
						} else {
							var key = indexKey(index, constants);
							elements = [
								for (entry in elements)
									if (entry.array.id == array.id ? distinctConstants(entry.index, key) : !sameType(entry.array.type, array.type)) entry
							];
							elements.push({array: array, index: key, value: value});
						}
					case ArrayGet(out, array, index):
						if (!plainArray(array.type)) {
							fields = [];
							elements = [];
						} else if (!excludedField(out.type, objects)) {
							var key = indexKey(index, constants),
								known:Null<IrValue> = null;
							for (entry in elements)
								if (entry.array.id == array.id && entry.index == key)
									known = entry.value;
							if (known != null && sameType(out.type, known.type)) {
								substitutions.set(out.id, known);
								drop = true;
							} else {
								elements = [
									for (entry in elements)
										if (entry.array.id != array.id || entry.index != key) entry
								];
								elements.push({array: array, index: key, value: out});
							}
						}
					default:
						if (mayWriteMemory(instruction)) {
							fields = [];
							elements = [];
						}
				}
				if (!drop)
					copy.instructions.push(located);
			}
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		if (!substitutions.keys().hasNext())
			return fn;
		// Rewrite the whole function: successor phis and debug bindings may use deleted outputs.
		for (block in blocks) {
			for (index in 0...block.instructions.length) {
				var located = block.instructions[index];
				block.instructions[index] = new Located(IrInliner.remap(located.value, use, function(id:Int):Int return id), located.provenance);
			}
			var term = block.terminator;
			if (term != null)
				block.terminator = new Located(switch term.value {
					case Return(value): Return(use(value));
					case Throw(value): Throw(use(value));
					case Rethrow(value): Rethrow(use(value));
					case Branch(condition, yes, no): Branch(use(condition), yes, no);
					case Jump(target): Jump(target);
				}, term.provenance);
		}
		var bindings:Array<IrDebugBinding> = [
			for (binding in fn.debugBindings)
				{
					identity: binding.identity,
					name: binding.name,
					value: use(binding.value),
					path: binding.path,
					scopeStart: binding.scopeStart,
					scopeEnd: binding.scopeEnd
				}
		];
		return new IrFunction(fn.name, fn.arguments, fn.result, blocks, bindings, fn.inlineHint, fn.retention);
	}

	/** Fields available on every normal path into each block. A null value is the analysis top. */
	static function incomingFields(fn:IrFunction, objects:Null<IrObjectTable>):Map<Int, Array<KnownField>> {
		var result:Map<Int, Array<KnownField>> = [], keys:Array<AvailableField> = [], seen:Map<String, Bool> = [], repeated = false;
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case BeginTry(_, _, _), EndTry(_, _), Catch(_): return result;
			case FieldGet(_, object, field), FieldSet(object, field, _) if (plainObject(object.type)):
				var key = object.id + ":" + field;
				if (seen.exists(key)) repeated = true;
				else { seen.set(key, true); keys.push({object: object.id, field: field, value: null}); }
			default:
		}
		if (!repeated || fn.blocks.length < 2) return result;
		var graph = new IrGraph(fn), outgoing:Map<Int, Array<AvailableField>> = [];
		for (id in graph.order) outgoing.set(id, keys.copy());
		var changed = true;
		while (changed) {
			changed = false;
			for (id in graph.order) {
				var before:Array<AvailableField> = [], predecessors = graph.predecessors.get(id);
				if (id != fn.blocks[0].id && predecessors != null && predecessors.length > 0) {
					before = outgoing.get(predecessors[0]).copy();
					for (i in 1...predecessors.length) before = intersectFields(before, outgoing.get(predecessors[i]));
				}
				result.set(id, [for (entry in before) if (entry.value != null)
					{object: entry.object, field: entry.field, value: entry.value}]);
				var after = before.copy();
				for (located in graph.block(id).instructions) switch located.value {
					case FieldSet(object, field, value):
						if (excludedField(value.type, objects) || !plainObject(object.type)) after = [];
						else after = [for (entry in after) if (entry.field != field) entry];
					case FieldGet(out, object, field):
						if (!plainObject(object.type)) after = [];
						else if (!excludedField(out.type, objects) && findField(after, object.id, field) == null)
							after.push({object: object.id, field: field, value: out});
					case ArraySet(array, _, value):
						if (!plainArray(array.type) || excludedField(value.type, objects)) after = [];
					case ArrayGet(_, array, _): if (!plainArray(array.type)) after = [];
					// Across blocks, even a non-writing call is an explicit barrier.
					case Call(_, _, _): after = [];
					default: if (mayWriteMemory(located.value)) after = [];
				}
				if (!sameFields(outgoing.get(id), after)) { outgoing.set(id, after); changed = true; }
			}
		}
		return result;
	}

	static function findField(fields:Array<AvailableField>, object:Int, name:String):Null<AvailableField> {
		for (entry in fields) if (entry.object == object && entry.field == name) return entry;
		return null;
	}

	static function intersectFields(left:Array<AvailableField>, right:Array<AvailableField>):Array<AvailableField> {
		var common:Array<AvailableField> = [];
		for (a in left) {
			var b = findField(right, a.object, a.field);
			if (b == null) continue;
			var leftValue = a.value, rightValue = b.value;
			if (leftValue == null) common.push(b);
			else if (rightValue == null || leftValue.id == rightValue.id && sameType(leftValue.type, rightValue.type)) common.push(a);
		}
		return common;
	}

	static function sameFields(left:Array<AvailableField>, right:Array<AvailableField>):Bool {
		if (left.length != right.length) return false;
		for (a in left) {
			var b = findField(right, a.object, a.field);
			if (b == null) return false;
			var leftValue = a.value, rightValue = b.value;
			if (leftValue == null) {
				if (rightValue != null) return false;
			} else {
				if (rightValue == null || leftValue.id != rightValue.id || !sameType(leftValue.type, rightValue.type)) return false;
			}
		}
		return true;
	}

	static function sameType(a:IrType, b:IrType):Bool
		return Std.string(a) == Std.string(b);

	/** A native-width store may change its input before a later load observes it. */
	static function storeNeedsNormalization(type:IrType, field:String, objects:Null<IrObjectTable>):Bool {
		if (objects == null) return false;
		var name:Null<String> = switch type { case Obj(value): value; default: null; };
		while (name != null) {
			var object = objects.get(name);
			if (object == null) return false;
			for (entry in object.fields) if (entry.name == field) {
				// A Float32 field rounds even when its enclosing object has no native layout.
				if (Type.enumEq(entry.type, F32)) return true;
				var native = IrFieldStorage.scalar(entry);
				if (native == null) return false;
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
			case Obj(name): var descriptor = objects == null ? null : objects.get(name); descriptor == null || descriptor.isValue;
			default: false;
		};

	static function indexKey(value:IrValue, constants:Map<Int, Int>):String {
		var literal = constants.get(value.id);
		return literal == null ? "v" + value.id : "c" + literal;
	}

	static function distinctConstants(a:String, b:String):Bool
		return a != b && StringTools.startsWith(a, "c") && StringTools.startsWith(b, "c");

	/** Unknown operations kill all facts. Dynamic arithmetic/comparisons can dispatch user code. */
	public static function mayWriteMemory(instruction:IrInstruction):Bool
		return switch instruction {
			case Call(_, name, _) if (name == IrReceiverCheck.NAME || name == IrReferenceIdentity.NAME): false;
			case Phi(_, _), ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstString(_, _), ConstBool(_, _), ConstNull(_), TypeValue(_, _),
				StaticDataAddress(_, _), PointerOffset(_, _, _), MemoryLoad(_, _, _, _), NewObject(_, _), IntToFloat(_, _), IntToInt64(_, _),
				FloatToInt(_, _), FloatToFloat(_, _), ArraySize(_, _), EnumIndex(_, _), EnumField(_, _, _, _): false;
			case Add(_, a, b), Sub(_, a, b), Mul(_, a, b), Div(_, a, b), Mod(_, a, b), BitAnd(_, a, b), BitOr(_, a, b), BitXor(_, a, b), ShiftLeft(_, a, b),
				ShiftRight(_, a, b), UnsignedShiftRight(_, a, b), Less(_, a, b), LessEqual(_, a, b), Equal(_, a, b): !primitive(a.type) || !primitive(b.type);
			default: true;
		};

	static function primitive(type:IrType):Bool
		return switch type {
			case I32, I64, F32, F64, Bool: true;
			default: false;
		};
}
