package compiler.ir.cfg;

import compiler.ir.Ir.IrType;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.cfg.Cfg;

/**
 * Replaces a local array iterator with an array and a position, before SSA construction.
 *
 * `var it = values.iterator(); while (it.hasNext()) use(it.next());` allocated an iterator object and made two
 * runtime calls per element. When a local holds only iterators created for it, and its loads feed nothing but
 * `hasNext` and `next`, nothing else can observe the object: `hasNext` becomes `position < array.length`, `next`
 * becomes `array[position]` followed by `position + 1`, and SSA construction turns the position into a loop phi.
 *
 * The array length and element are read at every call, as the runtime iterator does, so changing the array during
 * the loop behaves the same. Only element types whose raw array read is exactly what the iterator does are handled,
 * and functions with exception handling are skipped.
 */
class CfgIteratorReplacement {
	public static function run(cfg:CfgFunction):CfgFunction {
		var candidates:Map<String, IrType> = [];
		for (name => type in cfg.localTypes)
			switch type {
				case Iterator(element) if (replaceable(element)):
					candidates.set(name, element);
				default:
			}
		for (argument in cfg.arguments)
			candidates.remove(argument.name);
		if (!candidates.keys().hasNext())
			return cfg;
		// A catch handler sees the locals as they were when its try began, which source locals assigned in the body get
		// around by becoming cells. The position variable would not, so functions with a try are left alone.
		for (block in cfg.blocks)
			for (located in block.instructions)
				switch located.value {
					case BeginTry(_, _):
						return cfg;
					default:
				}

		// Pass 1: where iterators are created and loaded.
		var created:Map<Int, CfgValue> = [], loaded:Map<Int, String> = [];
		for (block in cfg.blocks)
			for (located in block.instructions)
				switch located.value {
					case IteratorNew(output, array):
						created.set(output.id, array);
					case LoadLocal(output, name) if (candidates.exists(name)):
						loaded.set(output.id, name);
					default:
				}

		// Pass 2: record the stores, and every use of an iterator value that is not the plain pattern. A load may only feed
		// hasNext/next; a created iterator may only be stored into a candidate local, once.
		var stores:Array<{name:String, value:Int}> = [],
			escaped:Map<Int, Bool> = [];
		function escape(value:CfgValue):Void {
			if (loaded.exists(value.id))
				candidates.remove(loaded.get(value.id));
			if (created.exists(value.id))
				escaped.set(value.id, true);
		}
		for (block in cfg.blocks) {
			for (located in block.instructions)
				switch located.value {
					case IteratorNew(_, _), LoadLocal(_, _):
					case StoreLocal(name, value) if (candidates.exists(name)):
						stores.push({name: name, value: value.id});
						// copying one iterator local into another aliases the object
						if (loaded.exists(value.id))
							candidates.remove(loaded.get(value.id));
					case IteratorHasNext(_, iterator):
						if (created.exists(iterator.id))
							escaped.set(iterator.id, true);
					case IteratorNext(output, iterator):
						if (created.exists(iterator.id))
							escaped.set(iterator.id, true);
						else if (loaded.exists(iterator.id)
							&& Std.string(output.type) != Std.string(candidates.get(loaded.get(iterator.id))))
							candidates.remove(loaded.get(iterator.id));
					default:
						for (value in operands(located.value))
							escape(value);
				}
			if (block.terminator != null)
				for (value in terminatorOperands(block.terminator.value))
					escape(value);
		}
		var storeCounts:Map<Int, Int> = [];
		for (store in stores)
			storeCounts.set(store.value, (storeCounts.exists(store.value) ? storeCounts.get(store.value) : 0) + 1);
		for (store in stores) {
			var count = storeCounts.get(store.value);
			if (!created.exists(store.value) || escaped.exists(store.value) || (count != null && count > 1))
				candidates.remove(store.name);
		}
		// The creations that will be replaced: stored once into a surviving candidate.
		var stored:Map<Int, String> = [];
		for (store in stores)
			if (candidates.exists(store.name))
				stored.set(store.value, store.name);
		if (!candidates.keys().hasNext())
			return cfg;

		// Rewrite.
		var nextValue = cfg.valueCount, localTypes = cfg.localTypes.copy();
		function fresh(type:IrType):CfgValue
			return new CfgValue(nextValue++, type);
		for (name => element in candidates) {
			localTypes.set(arrayLocal(name), Array(element));
			localTypes.set(positionLocal(name), I32);
		}
		for (block in cfg.blocks) {
			var rewritten:Array<Located<CfgInstruction>> = [];
			for (located in block.instructions) {
				var provenance = located.provenance;
				inline function add(instruction:CfgInstruction)
					rewritten.push(new Located(instruction, provenance));
				switch located.value {
					case IteratorNew(output, _) if (stored.exists(output.id)):
						// dropped: the store that follows records the array and a zero position instead
					case StoreLocal(name, value) if (candidates.exists(name) && stored.exists(value.id)):
						var zero = fresh(I32);
						add(StoreLocal(arrayLocal(name), created.get(value.id)));
						add(ConstInt(zero, 0));
						add(StoreLocal(positionLocal(name), zero));
					case LoadLocal(output, name) if (loaded.exists(output.id) && candidates.exists(name)):
						// dropped: its only uses are rewritten below
					case IteratorHasNext(output, iterator) if (loaded.exists(iterator.id) && candidates.exists(loaded.get(iterator.id))):
						var name = loaded.get(iterator.id),
							element = candidates.get(name);
						var array = fresh(Array(element)),
							position = fresh(I32),
							size = fresh(I32);
						add(LoadLocal(array, arrayLocal(name)));
						add(LoadLocal(position, positionLocal(name)));
						add(ArraySize(size, array));
						add(Less(output, position, size));
					case IteratorNext(output, iterator) if (loaded.exists(iterator.id) && candidates.exists(loaded.get(iterator.id))):
						var name = loaded.get(iterator.id),
							element = candidates.get(name);
						var array = fresh(Array(element)),
							position = fresh(I32),
							one = fresh(I32),
							following = fresh(I32);
						add(LoadLocal(array, arrayLocal(name)));
						add(LoadLocal(position, positionLocal(name)));
						add(ArrayGet(output, array, position));
						add(ConstInt(one, 1));
						add(Add(following, position, one));
						add(StoreLocal(positionLocal(name), following));
					default:
						rewritten.push(located);
				}
			}
			block.instructions.resize(0);
			for (located in rewritten)
				block.instructions.push(located);
		}
		return new CfgFunction(cfg.name, cfg.arguments, cfg.result, cfg.blocks, localTypes, nextValue, cfg.debugLocals);
	}

	/** Element types for which `array[position]` is exactly what the runtime iterator reads. */
	static function replaceable(element:IrType):Bool
		return switch element {
			case I32, I64, F64, Bool, Bytes, Obj(_): true;
			default: false;
		};

	static function arrayLocal(name:String):String
		return name + "$iterator-array";

	static function positionLocal(name:String):String
		return name + "$iterator-position";

	static function terminatorOperands(terminator:CfgTerminator):Array<CfgValue>
		return switch terminator {
			case Return(value), Throw(value), Rethrow(value), Branch(value, _, _): [value];
			case Jump(_): [];
		};

	/** Every value an instruction reads. */
	static function operands(instruction:CfgInstruction):Array<CfgValue>
		return switch instruction {
			case ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstString(_, _), StaticDataAddress(_, _), ConstBool(_, _), ConstNull(_), TypeValue(_, _),
				BeginTry(_, _), EndTry(_), Catch(_), LoadLocal(_, _), GlobalGet(_, _), StaticClosure(_, _), NewObject(_, _): [];
			case ToDyn(_, value), IntToFloat(_, value), IntToInt64(_, value), FloatToInt(_, value), SafeCast(_, value), StoreLocal(_, value),
				GlobalSet(_, value), InstanceClosure(_, _, value), ToVirtual(_, value), FieldGet(_, value, _), ArraySize(_, value), IteratorNew(_, value),
				IteratorHasNext(_, value), IteratorNext(_, value), EnumIndex(_, value), EnumField(_, value, _, _), MemoryLoad(_, value, _, _): [value];
			case Add(_, a, b), Sub(_, a, b), Mul(_, a, b), Div(_, a, b), Mod(_, a, b), BitAnd(_, a, b), BitXor(_, a, b), BitOr(_, a, b), ShiftLeft(_, a, b),
				ShiftRight(_, a, b), UnsignedShiftRight(_, a, b), Less(_, a, b), LessEqual(_, a, b), Equal(_, a, b), FieldSet(a, _, b), ArrayGet(_, a, b),
				PointerOffset(_, a, b): [a, b];
			case ArraySet(array, index, value): [array, index, value];
			case MemoryStore(pointer, value, _): [pointer, value];
			case Call(_, _, arguments), CNativeCall(_, _, arguments), MakeEnum(_, _, _, arguments): arguments;
			case CallClosure(_, receiver, arguments), MethodCall(_, receiver, _, arguments): [receiver].concat(arguments);
		};
}
