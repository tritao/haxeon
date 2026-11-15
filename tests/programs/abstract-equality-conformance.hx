import haxeon.Equality;
import haxeon.Hashing;

abstract IntId(Int) {
	public inline function new(value:Int) this = value;
}

abstract IntList(Array<Int>) {
	public inline function new(value:Array<Int>) this = value;
}

function keepEquatable < T:Equatable > (value:T):T return value;
function keepHashable < T:Hashable > (value:T):T return value;

function main():Int {
	var a = new IntId(7), b = new IntId(7), c = new IntId(8);
	if (!Equality.equals(a, b) || Equality.equals(a, c)) return 1;
	if (Hashing.hash(a) != Hashing.hash(b)) return 2;
	var dynamicA:Dynamic = a, dynamicB:Dynamic = b;
	if (!Equality.equals(dynamicA, dynamicB)) return 3;
	var first = new IntList([1, 2]), second = new IntList([1, 2]), different = new IntList([1, 3]);
	if (!Equality.equals(first, second) || Equality.equals(first, different)) return 4;
	if (Equality.sameForChange(first, second) || !Equality.sameForChange(first, first)) return 8;
	if (!Equality.equals(keepEquatable(first), second) || !Equality.equals(keepHashable(a), b)) return 7;
	var nested:Array<IntList> = [first],
		nestedEqual:Array<IntList> = [second],
		nestedDifferent:Array<IntList> = [different];
	if (!Equality.equals(nested, nestedEqual) || Equality.equals(nested, nestedDifferent)) return 9;
	var nullable:Null<IntList> = first, nullableEqual:Null<IntList> = second;
	if (!Equality.equals(nullable, nullableEqual)) return 10;
	nullableEqual = null;
	if (Equality.equals(nullable, nullableEqual)) return 11;
	var wrapped:Array<IntId> = [a, b], equal:Array<IntId> = [b, a];
	if (!Equality.equals(wrapped, equal)) return 5;
	var map:Map<IntId, Int> = [];
	map.set(a, 42);
	if (map.get(b) != 42) return 6;
	return 42;
}
