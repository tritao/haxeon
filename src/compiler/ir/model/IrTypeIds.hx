package compiler.ir.model;

import compiler.ir.model.Ir.IrType;
import sys.thread.Mutex;

/**
 * Dense ids for IR types, one table for the process, like `IrSymbol`: equal types (by `IrTypeIdentity.same`) get one id, in the
 * order the process first sees them, so ids may index tables but must never decide the order of anything a compile writes. An
 * `IrBody` holds its types as these ids, so two of its types compare as two integers, and a cache by id stays valid across
 * compiles. The table only grows.
 */
@:nullSafety(Strict)
class IrTypeIds {
	/** The types without parts have the first ids, in `simpleId`'s order, so most lookups take neither the lock nor a hash. */
	static inline final SIMPLE_COUNT = 11;

	@:processWide("interned types: a type always denotes the same id, and the table only grows")
	static final ids = simpleIds();

	@:processWide("guards interning, which the compile and census threads may both do")
	static final lock = new Mutex();

	/**
	 * The interned types by id, at a length past the last id: interning never resizes it but replaces it with a longer copy, so
	 * `type`, which every read of a body's types goes through, is one array read with no lock. An id reaches a reader only after
	 * `id` stored it, in the array the reader then finds here or a later copy.
	 */
	@:processWide("interned types, by id: only filled, or replaced by a longer copy, under the lock")
	static var byId = firstTypes();

	@:processWide("how many types are interned, written under the lock")
	static var count = SIMPLE_COUNT;

	/** The id of `type`, given the first time a type equal to it is seen. */
	public static function id(type:IrType):Int {
		var simple = simpleId(type);
		if (simple >= 0)
			return simple;
		lock.acquire();
		var result = intern(type);
		lock.release();
		return result;
	}

	/** The type with id `id`, which must be one `id` has given: the table's own instance, shared by everything that reads it. */
	public static inline function type(id:Int):IrType
		return byId[id];

	static inline function simpleId(type:IrType):Int
		return switch type {
			case Void: 0;
			case I32: 1;
			case I64: 2;
			case Bool: 3;
			case F32: 4;
			case F64: 5;
			case Bytes: 6;
			case RawPtr: 7;
			case ManagedBytes: 8;
			case Dyn: 9;
			case TypeRef: 10;
			default: -1;
		};

	static function simpleTypes():Array<IrType>
		return [Void, I32, I64, Bool, F32, F64, Bytes, RawPtr, ManagedBytes, Dyn, TypeRef];

	static function simpleIds():IrTypeMap<Int> {
		var map = new IrTypeMap<Int>(), types = simpleTypes();
		for (index in 0...types.length)
			map.set(types[index], index);
		return map;
	}

	static function firstTypes():Array<IrType> {
		var types = simpleTypes();
		types.resize(1 << 12);
		return types;
	}

	/**
	 * `id` under the lock. A new type is kept as the table's own instance, its parts the table's instances and its argument list
	 * a copy, so a caller that later changes a list it passed cannot change a key.
	 */
	static function intern(type:IrType):Int {
		var known = ids.get(type);
		if (known != null)
			return known;
		var own = switch type {
			case Nullable(element): Nullable(part(element));
			case Array(element): Array(part(element));
			case Iterator(element): Iterator(part(element));
			case Function(arguments, result): Function([for (argument in arguments) part(argument)], part(result));
			case _: type;
		}
		var result = count, types = byId;
		if (result == types.length) {
			types = types.copy();
			types.resize(result * 2);
			byId = types;
		}
		types[result] = own;
		ids.set(own, result);
		count = result + 1;
		return result;
	}

	static inline function part(of:IrType):IrType {
		var simple = simpleId(of);
		return IrTypeIds.type(simple >= 0 ? simple : intern(of));
	}
}
