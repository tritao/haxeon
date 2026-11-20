package compiler.ir;

import compiler.ir.Ir.IrType;

/**
 * Dense ids for IR types, one table per program: equal types (by `IrTypeIdentity.same`) get one id, in the order they are first
 * seen, so ids may index tables but must never decide the order of anything a compile writes. An `IrBody` holds its types as these
 * ids, so two of its types compare as two integers.
 */
class IrTypeIds {
	final ids = new IrTypeMap<Int>();
	final types:Array<IrType> = [];

	public function new() {}

	/** The id of `type`, given the first time a type equal to it is seen. */
	public function id(type:IrType):Int {
		var known = ids.get(type);
		if (known != null)
			return known;
		var result = types.length;
		types.push(type);
		ids.set(type, result);
		return result;
	}

	/** The type with id `id`: the first one seen of the types equal to it. */
	public inline function type(id:Int):IrType
		return types[id];

	/** How many types have ids: every id is below it. */
	public var count(get, never):Int;

	inline function get_count():Int
		return types.length;
}
