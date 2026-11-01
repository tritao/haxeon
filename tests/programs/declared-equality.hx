class Record implements Equatable {
	public final x:Int;
	public function new(x:Int) this.x = x;
}

struct Pair : Hashable, Diffable {
	public final x:Int;
	public function new(x:Int) this.x = x;
}

class Modulo implements Equatable {
	public final x:Int;
	public function new(x:Int) this.x = x;
	public function equals(other:Modulo):Bool return x % 10 == other.x % 10;
}

class Hashed implements Hashable {
	public final x:Int;
	public function new(x:Int) this.x = x;
	public function equals(other:Hashed):Bool return x % 10 == other.x % 10;
	public function hash():Int return x % 10;
}

class RecordKey implements Hashable {
	public final id:Int;
	public function new(id:Int) this.id = id;
}

class Editable implements Diffable {
	public var x:Int;
	public var y:Int;
	public function new(x:Int, y:Int) { this.x = x; this.y = y; }
}

class Identity {
	public function new() {}
}

class RefChanges implements Diffable {
	public var item:Identity;
	public function new(item:Identity) this.item = item;
}

struct Scalar : Hashable {
	public final value:Float;
	public function new(value:Float) this.value = value;
}

struct Nested : Hashable {
	public final value:Null<Scalar>;
	public function new(value:Null<Scalar>) this.value = value;
}

struct Managed : Equatable {
	public final label:String;
	public final record:Null<Record>;
	public function new(label:String, record:Null<Record>) { this.label = label; this.record = record; }
}

struct NativeNumbers : Hashable {
	public final small:Int16;
	public final wide:haxe.Int64;
	public final fraction:Float32;
	public final unsigned:UInt64;
	public function new(negative:Bool) {
		this.small = cast 3; this.wide = haxe.Int64.ofInt(4); this.fraction = cast (negative ? -0.0 : 0.0);
		this.unsigned = cast 5;
	}
}

struct ModValue : Hashable {
	public final value:Int;
	public function new(value:Int) this.value = value;
	public function equals(other:ModValue):Bool return value % 10 == other.value % 10;
	public function hash():Int return value % 10;
}

struct EditableValue : Diffable {
	public var x:Int;
	public var y:Int;
	public function new(x:Int, y:Int) { this.x = x; this.y = y; }
}

function keepEquatable<T:Equatable>(value:T):T return value;
function keepHashable<T:Hashable>(value:T):T return value;

function main():Int {
	var a = new Record(7);
	var b = new Record(7);
	var c = new Record(8);
	var pair = new Pair(3);
	var first:Null<Record> = a;
	var second:Null<Record> = b;
	var before = new Editable(1, 2);
	var after = new Editable(1, 3);
	var target = new Editable(1, 2);
	var mask = haxeon.Diff.mask(before, after);
	var applied = haxeon.Diff.apply(target, before, after);
	var valueBefore = new EditableValue(1, 2), valueAfter = new EditableValue(1, 3), valueTarget = new EditableValue(1, 2);
	var valueMask = haxeon.Diff.mask(valueBefore, valueAfter), valueApplied = haxeon.Diff.apply(valueTarget, valueBefore, valueAfter);
	var zero = new Scalar(0.0);
	var optionalZero:Null<Scalar> = zero;
	var absentScalar:Null<Scalar> = null;
	var negativeZero = new Scalar(-0.0);
	var nan = new Scalar(Math.NaN);
	var numbers = new NativeNumbers(false);
	var sameNumbers = new NativeNumbers(true);
	var identity = new Identity();
	var refBefore = new RefChanges(identity);
	var refSame = new RefChanges(identity);
	var refChanged = new RefChanges(new Identity());
	var pairMap = new Map<Pair, String>();
	pairMap.set(new Pair(4), "first");
	pairMap.set(new Pair(4), "last");
	var pairMapCopy = pairMap.copy();
	var pairKeyTotal = 0;
	for (key in pairMap.keys()) pairKeyTotal += key.x;
	var pairValueTotal = 0;
	for (value in pairMap.values()) pairValueTotal += value.length;
	var classMap = new Map<Hashed, Int>();
	classMap.set(new Hashed(2), 20);
	classMap.set(new Hashed(12), 30);
	var classMapMatches = classMap.size() == 1 && classMap.get(new Hashed(22)) == 30 && classMap.exists(new Hashed(32));
	var classMapRemoved = classMap.remove(new Hashed(42));
	classMap.clear();
	var synthesizedClassMap = new Map<RecordKey, String>();
	synthesizedClassMap.set(new RecordKey(7), "seven");
	return a == b && a != c && pair == new Pair(3) && pair != new Pair(4)
		&& new Modulo(1) == new Modulo(11)
		&& haxeon.Equality.equals(new Modulo(1), new Modulo(11)) && first == second
		&& haxeon.Hashing.hash(new Hashed(11)) == haxeon.Hashing.hash(new Hashed(1))
		&& haxeon.Hashing.hash(pair) == haxeon.Hashing.hash(new Pair(3))
		&& mask == haxeon.Diff.bit(Editable, "y") && applied == mask && target.y == 3
		&& valueMask == 2 && valueApplied == valueMask && valueTarget.y == 3
		&& haxeon.Diff.all(Editable) == 3 && zero == negativeZero
		&& haxeon.Hashing.hash(zero) == haxeon.Hashing.hash(negativeZero)
		&& haxeon.Hashing.hash(optionalZero) == haxeon.Hashing.hash(zero) && haxeon.Hashing.hash(absentScalar) == 0 && nan != nan
		&& new Nested(zero) == new Nested(negativeZero) && new Nested(null) != new Nested(zero)
		&& haxeon.Hashing.hash(new Nested(zero)) == haxeon.Hashing.hash(new Nested(negativeZero))
		&& new Managed("same", a) == new Managed("same", b)
		&& new Managed("same", null) != new Managed("same", a) && numbers == sameNumbers
		&& haxeon.Hashing.hash(numbers) == haxeon.Hashing.hash(sameNumbers)
		&& new ModValue(1) == new ModValue(11)
		&& haxeon.Equality.equals(new ModValue(1), new ModValue(11))
		&& haxeon.Hashing.hash(new ModValue(1)) == haxeon.Hashing.hash(new ModValue(11))
		&& haxeon.Diff.mask(refBefore, refSame) == 0 && haxeon.Diff.mask(refBefore, refChanged) == 1
		&& pairMap.size() == 1 && pairMap.get(new Pair(4)) == "last" && pairMapCopy.get(new Pair(4)) == "last"
		&& pairKeyTotal == 4 && pairValueTotal == 4 && classMapMatches && classMapRemoved && classMap.size() == 0
		&& synthesizedClassMap.get(new RecordKey(7)) == "seven"
		&& keepEquatable(7) == 7 && keepHashable("value") == "value" ? 42 : 0;
}
