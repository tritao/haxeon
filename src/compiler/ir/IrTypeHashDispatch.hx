package compiler.ir;

import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrBlock;

/** Balanced dispatch on stable type hashes. Arms must resolve hash collisions by exact type tests. */
class IrTypeHashDispatch {
	public static function emit(builder:IrBuilder, hash:IrValue, hashes:Array<Int>, arm:Int->Void, missing:IrBlock):Void {
		var ordered = hashes.copy();
		ordered.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		// Runtime object queries return zero for non-objects. A real type can hash
		// to zero too, so use the fast fallback only when no arm owns that hash.
		if (ordered.length > 0 && ordered.indexOf(0) < 0) {
			var objects = builder.createBlock();
			builder.branch(builder.equal(hash, builder.constInt(0)), missing, objects);
			builder.select(objects);
		}
		function branch(low:Int, high:Int):Void {
			if (low >= high) { builder.jump(missing); return; }
			var mid = (low + high) >> 1, value = ordered[mid], matched = builder.createBlock(), different = builder.createBlock();
			builder.branch(builder.equal(hash, builder.constInt(value)), matched, different);
			builder.select(matched); arm(value);
			builder.select(different);
			var lower = builder.createBlock(), higher = builder.createBlock();
			builder.branch(builder.less(hash, builder.constInt(value)), lower, higher);
			builder.select(lower); branch(low, mid);
			builder.select(higher); branch(mid + 1, high);
		}
		branch(0, ordered.length);
	}
}
