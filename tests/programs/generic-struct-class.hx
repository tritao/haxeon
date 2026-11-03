interface MeasuredOwnerValue {
	function measure():Int;
	function advance():Int;
}

interface ValueSlot<T> {
	function get():T;
	function set(value:T):Void;
}

class Owner {
	public final id:Int;
	public function new(id:Int) this.id = id;
}

struct Payload implements MeasuredOwnerValue implements ValueSlot<Int> {
	public var number:Int;
	public var owner:Owner;
	public function new(number:Int, owner:Owner) { this.number = number; this.owner = owner; }
	public function measure():Int return number;
	public function advance():Int { number++; return number; }
	public function get():Int return number;
	public function set(value:Int):Void number = value;
}

struct OtherPayload {
	public var number:Int;
	public var owner:Owner;
	public function new(number:Int, owner:Owner) { this.number = number; this.owner = owner; }
}

class Box<T> {
	public var value:T;
	public final marker:Int;
	public function new(value:T) { this.value = value; marker = 7; }
	public function get():T return value;
	public function replace(value:T):Void this.value = value;
}

class Derived<T> extends Box<T> {
	public function new(value:T) super(value);
	override public function get():T return super.get();
}

class Concrete extends Box<Payload> {
	public function new(value:Payload) super(value);
	override public function get():Payload return super.get();
}

class Pair<A, B> {
	public var first:A;
	public var second:B;
	public function new(first:A, second:B) { this.first = first; this.second = second; }
}

class Meter<T:MeasuredOwnerValue> {
	public var value:T;
	public function new(value:T) this.value = value;
	public function measure():Int return value.measure();
}

function main():Int {
	var owner = new Owner(7);
	var box:Box<Payload> = new Derived<Payload>(new Payload(19, owner));
	var other = new Box<OtherPayload>(new OtherPayload(4, owner));
	var meter = new Meter<Payload>(new Payload(23, owner));
	if (meter.measure() != 23) return 21;
	var measured:MeasuredOwnerValue = meter.value;
	meter.value.number = 24;
	if (measured.measure() != 23 || meter.measure() != 24) return 22;
	var unboxed:Payload = cast measured;
	if (unboxed.number != 23 || unboxed.owner != owner) return 23;
	unboxed.number = 31;
	if (measured.measure() != 23 || measured.advance() != 24 || meter.measure() != 24) return 24;
	var dynamicMeasured:Dynamic = measured;
	if (!Std.isOfType(dynamicMeasured, Payload) || !Std.isExactType(dynamicMeasured, Payload)) return 26;
	var dynamicUnboxed:Payload = cast dynamicMeasured;
	if (dynamicUnboxed.number != 24 || dynamicUnboxed.owner != owner) return 25;
	var wrongCastCaught = false;
	try { var wrong:OtherPayload = cast dynamicMeasured; } catch (_:Dynamic) wrongCastCaught = true;
	if (!wrongCastCaught) return 28;
	var slot:ValueSlot<Int> = meter.value;
	slot.set(35);
	if (slot.get() != 35 || meter.measure() != 24) return 27;
	var dynamicPayload:Dynamic = meter.value;
	var fromDynamic:MeasuredOwnerValue = cast dynamicPayload;
	if (fromDynamic.advance() != 25 || meter.measure() != 24) return 29;
	var boxAlias:Dynamic = measured;
	var sameBox:ValueSlot<Int> = cast boxAlias;
	sameBox.set(36);
	if (measured.measure() != 36) return 30;
	var concrete = new Concrete(new Payload(8, owner));
	if (concrete.get().number != 8 || concrete.marker != 7) return 7;
	var referenceBox = new Box<Owner>(owner);
	if (!Std.isOfType(box, Box) || !Std.isOfType(box, Derived) || Std.isExactType(box, Box)
		|| !Std.isExactType(box, Derived) || !Std.isOfType(concrete, Box) || Std.isExactType(concrete, Box)
		|| !Std.isExactType(referenceBox, Box) || Std.isOfType(owner, Box) || Std.isOfType(null, Box)) return 20;
	var referenceRead:Void->Owner = referenceBox.get;
	if (referenceRead() != owner) return 10;
	var dynamicBox = new Box<Dynamic>(23);
	if (dynamicBox.get() != 23) return 11;
	var pair = new Pair<Payload, Int>(new Payload(2, owner), 7);
	var pairView:Pair<Dynamic, Dynamic> = pair;
	var pairRejected = false;
	try pairView.second = "wrong" catch (_:Dynamic) pairRejected = true;
	if (!pairRejected || pair.second != 7 || pair.first.number != 2) return 19;
	var optional:Box<Null<Payload>> = new Box<Null<Payload>>(null);
	if (optional.value != null) return 12;
	optional.value = new Payload(12, owner);
	var saved = optional.get();
	if (saved == null || saved.number != 12 || saved.owner != owner) return 13;
	optional.value = null;
	if (optional.value != null || saved.number != 12) return 14;
	var optionalView:Box<Dynamic> = optional;
	optionalView.value = new Payload(13, owner);
	var optionalRead = optional.value;
	if (optionalRead == null || optionalRead.number != 13) return 15;
	var optionalRejected = false;
	try optionalView.value = 123 catch (_:Dynamic) optionalRejected = true;
	optionalRead = optional.value;
	if (!optionalRejected || optionalRead == null || optionalRead.number != 13) return 17;
	optionalView.value = null;
	if (optional.value != null) return 16;
	optionalRejected = false;
	try optionalView.value = 123 catch (_:Dynamic) optionalRejected = true;
	if (!optionalRejected || optional.value != null) return 18;
	var before = box.get();
	box.value.number = 21;
	if (before.number != 19 || box.get().number != 21 || box.get().owner != owner || box.marker != 7) return 1;
	var read:Void->Payload = box.get;
	if (read().number != 21) return 8;
	var erased:Box<Dynamic> = box;
	var erasedValue:Payload = cast erased.get();
	if (erasedValue.number != 21 || erasedValue.owner != owner) return 2;
	var erasedRead:Void->Dynamic = erased.get;
	var erasedSnapshot:Payload = cast erasedRead();
	if (erasedSnapshot.number != 21) return 9;
	var fromField:Payload = cast erased.value;
	fromField.number = 3;
	if (box.value.number != 21) return 4;
	erased.value = new Payload(34, owner);
	if (box.value.number != 34) return 5;
	var rejected = false;
	try erased.value = 123 catch (_:Dynamic) rejected = true;
	if (!rejected || box.value.number != 34) return 6;
	erased.replace(new Payload(35, owner));
	if (box.get().number != 35 || box.get().owner != owner || other.get().number != 4 || erased != cast box) return 3;
	var copy = box.get();
	copy.number = 99;
	return box.get().number + owner.id;
}
