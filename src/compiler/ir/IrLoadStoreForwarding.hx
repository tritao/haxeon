package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance.Located;

private typedef KnownField = {final object:Int; final field:String; final value:IrValue;}
private typedef KnownElement = {final array:IrValue; final index:String; final value:IrValue;}

/** Block-local reload elimination. Stores and the input function are never changed. */
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
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var fields:Array<KnownField> = [],
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

	static function sameType(a:IrType, b:IrType):Bool
		return Std.string(a) == Std.string(b);

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
			case Phi(_, _), ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstString(_, _), ConstBool(_, _), ConstNull(_), TypeValue(_, _),
				StaticDataAddress(_, _), PointerOffset(_, _, _), MemoryLoad(_, _, _, _), NewObject(_, _), IntToFloat(_, _), IntToInt64(_, _),
				FloatToInt(_, _), ArraySize(_, _), EnumIndex(_, _), EnumField(_, _, _, _): false;
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
