import haxeon.Hashing;

enum AuditKey implements Hashable {

	Empty;
	Item(value:Int);
}
enum AuditTag {
	Ready;
	Waiting;
}

enum OtherAuditTag {
	Started;
	Stopped;
}

class AuditObject {
	public function new() {}

	public function toString():String
		return "custom";
}

enum AuditPayload {
	Count(value:Int);
	Pair(first:Int, second:String);
	Nested(value:AuditKey);
	Mixed(flag:Bool, value:Null<String>);
	Tagged(value:AuditTag);
	OtherTagged(value:OtherAuditTag);
	Number(value:Float);
	Large(value:haxe.Int64);
	Optional(value:Null<Int>);
	Object(value:AuditObject);
	Items(values:Array<Int>);
	Erased(value:Dynamic);
}

function main():Int {
	var first:AuditKey = Item(7),
		same:AuditKey = Item(7),
		other:AuditKey = Item(8);
	var erased:Dynamic = first,
		erasedSame:Dynamic = same,
		erasedOther:Dynamic = other;
	if (Reflect.compare(erased, erasedSame) != 0xAABBCCDD || Reflect.compare(null, erased) != 0xAABBCCDD)
		return 1;
	if (!(erased == erasedSame) || erased == erasedOther || !Type.enumEq(erased, erasedSame))
		return 2;
	if (Std.string(erased) != Std.string(first))
		return 3;
	if (Std.string(erased) != "Item(7)")
		return 6;
	var count:Dynamic = AuditPayload.Count(9);
	if (Std.string(count) != "Count(9)")
		return 15;
	var negative:Dynamic = AuditPayload.Count(-2147483648);
	if (Std.string(negative) != "Count(-2147483648)")
		return 18;
	var pair:Dynamic = AuditPayload.Pair(3, "abc");
	var nested:Dynamic = AuditPayload.Nested(Item(7));
	var mixed:Dynamic = AuditPayload.Mixed(true, null);
	if (Std.string(pair) != "Pair(3,abc)")
		return 7;
	if (Std.string(nested) != "Nested(Item(7))")
		return 8;
	if (Std.string(mixed) != "Mixed(true,null)")
		return 9;
	var tagged:Dynamic = AuditPayload.Tagged(Ready);
	if (Std.string(tagged) != "Tagged(Ready)")
		return 10;
	var otherTagged:Dynamic = AuditPayload.OtherTagged(Started);
	if (Std.string(otherTagged) != "OtherTagged(Started)")
		return 16;
	var number:Dynamic = AuditPayload.Number(2.5),
		present:Dynamic = AuditPayload.Optional(7),
		absent:Dynamic = AuditPayload.Optional(null);
	if (Std.string(number) != "Number(2.5)")
		return 11;
	var large:Dynamic = AuditPayload.Large(haxe.Int64.make(1, 1));
	if (Std.string(large) != "Large(4294967297)")
		return 17;
	var negativeLarge:Dynamic = AuditPayload.Large(haxe.Int64.make(-1, -1));
	if (Std.string(negativeLarge) != "Large(-1)")
		return 19;
	if (Std.string(present) != "Optional(7)" || Std.string(absent) != "Optional(null)")
		return 12;
	var object:Dynamic = AuditPayload.Object(new AuditObject());
	if (Std.string(object) != "Object(custom)")
		return 13;
	var items:Dynamic = AuditPayload.Items([1, 2]),
		erasedItems:Dynamic = AuditPayload.Erased([3, 4]);
	if (Std.string(items) != "Items([1, 2])" || Std.string(erasedItems) != "Erased([3, 4])")
		return 14;
	var restored:AuditKey = cast erased;
	if (Hashing.hash(restored) != Hashing.hash(same))
		return 4;
	var keys:Map<AuditKey, Int> = [];
	keys.set(first, 42);
	if (keys.get(same) != 42 || keys.exists(other))
		return 5;
	return 42;
}
