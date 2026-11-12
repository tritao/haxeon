import haxeon.Hashing;

enum AuditKey implements Hashable {
	Empty;
	Item(value:Int);
}

function main():Int {
	var first:AuditKey = Item(7), same:AuditKey = Item(7), other:AuditKey = Item(8);
	var erased:Dynamic = first, erasedSame:Dynamic = same, erasedOther:Dynamic = other;
	if (Reflect.compare(erased, erasedSame) != 0xAABBCCDD || Reflect.compare(null, erased) != 0xAABBCCDD) return 1;
	if (!(erased == erasedSame) || erased == erasedOther || !Type.enumEq(erased, erasedSame)) return 2;
	if (Std.string(erased) != Std.string(first)) return 3;
	// Characterize the current target difference before replacing fallback dispatch.
	#if wasm
	if (Std.string(erased) != "Object") return 6;
	#else
	if (Std.string(erased) != "Item(7)") return 6;
	#end
	var restored:AuditKey = cast erased;
	if (Hashing.hash(restored) != Hashing.hash(same)) return 4;
	var keys:Map<AuditKey, Int> = [];
	keys.set(first, 42);
	if (keys.get(same) != 42 || keys.exists(other)) return 5;
	return 42;
}
