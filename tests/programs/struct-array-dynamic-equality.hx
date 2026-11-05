struct DynamicArrayItem implements Equatable {
	public var value:Int;
	public var label:String;
	public function new(value:Int) { this.value = value; label = "managed"; }
	public function equals(other:DynamicArrayItem):Bool return value % 10 == other.value % 10 && label == other.label;
}

struct ReflectedArrayItem implements Equatable {
	public var value:Int;
	public function new(value:Int) this.value = value;
	public function equals(other:ReflectedArrayItem):Bool return value % 10 == other.value % 10;
}

struct OptionalArrayItem implements Equatable {
	public var item:Null<DynamicArrayItem>;
	public function new(item:Null<DynamicArrayItem>) this.item = item;
}

struct IeeeArrayItem implements Equatable {
	public var value:Float;
	public function new(value:Float) this.value = value;
}

class ReflectedArrayOwner {
	public var item:ReflectedArrayItem;
	public function new(value:Int) item = new ReflectedArrayItem(value);
}

struct NonEquatableItem {
	public var value:Int;
	public function new(value:Int) this.value = value;
}

// Their nominal IR type IDs collide under the runtime's stable hash.
struct CaxscQFXbw implements Equatable {
	public var value:Int;
	public function new(value:Int) this.value = value;
	public function equals(other:CaxscQFXbw):Bool return value == other.value;
}
struct CVqowVrIwv implements Equatable {
	public var value:Int;
	public function new(value:Int) this.value = value;
	public function equals(other:CVqowVrIwv):Bool return value == other.value;
}

class NonEquatableOwner {
	public var item:NonEquatableItem;
	public function new() item = new NonEquatableItem(1);
}

struct MutatingArrayItem implements Equatable {
	public var value:Int;
	public function new(value:Int) this.value = value;
	public function equals(other:MutatingArrayItem):Bool {
		if (value == 2 && MutationFixture.shrink) {
			MutationFixture.shrink = false;
			MutationFixture.items.pop();
		}
		if (value == 2 && MutationFixture.replace) {
			MutationFixture.replace = false;
			MutationFixture.items[1] = new MutatingArrayItem(99);
		}
		return value == other.value;
	}
}

class MutationFixture {
	public static var items:Array<MutatingArrayItem>;
	public static var shrink:Bool;
	public static var replace:Bool;
	public static function prepare():Void {
		items = [new MutatingArrayItem(1), new MutatingArrayItem(2)];
		shrink = true;
		replace = false;
	}
}

// This function has no typed struct lookup: the Dynamic view itself must retain
// enough information to request and dispatch the element's equality.
function erasedOnly():Int {
	var values = [new DynamicArrayItem(1), new DynamicArrayItem(2), new DynamicArrayItem(12)];
	var view:Array<Dynamic> = cast values;
	if (view.indexOf(new DynamicArrayItem(22)) != 1) return 1;
	if (!view.contains(new DynamicArrayItem(11))) return 2;
	if (!view.remove(new DynamicArrayItem(22)) || values.length != 2 || values[1].value != 12) return 3;
	return 0;
}

struct SelfMutatingArrayItem implements Equatable {
	public var value:Int;
	public var label:String;
	public function new(value:Int) { this.value = value; label = "owned"; }
	public function equals(other:SelfMutatingArrayItem):Bool {
		var result = value % 10 == other.value % 10;
		value = 100; label = "left";
		other.value = 200; other.label = "right";
		return result;
	}
}

// Compare already boxed values and typed lane elements repeatedly; dispatch
// itself must not allocate at either boundary.
class DynamicArrayEqualityCensus {
	static var left:Dynamic;
	static var right:Dynamic;
	static var values:Array<DynamicArrayItem>;
	static var mutableLeft:Dynamic;
	static var mutableRight:Dynamic;
	static var interfaceLeft:Dynamic;
	static var interfaceRight:Dynamic;
	public static function prepare():Void {
		left = new DynamicArrayItem(2);
		right = new DynamicArrayItem(12);
		values = [new DynamicArrayItem(1), new DynamicArrayItem(2)];
		mutableLeft = new SelfMutatingArrayItem(1);
		mutableRight = new SelfMutatingArrayItem(11);
		var view:Equatable = new DynamicArrayItem(3);
		interfaceLeft = view;
		interfaceRight = new DynamicArrayItem(13);
	}
	public static function perform(n:Int):Int {
		var result = 0;
		for (_ in 0...n) {
			if (left == right) result++;
			if (mutableLeft == mutableRight) result++;
			if (interfaceLeft == interfaceRight) result++;
			if (interfaceRight == interfaceLeft) result++;
			if (values.indexOf(new DynamicArrayItem(22)) == 1) result++;
		}
		return result;
	}
}

class ArrayEqualityOwner<T> {
	public var value:T;
	public function new(value:T) this.value = value;
}

// No typed lookup, struct-to-Dynamic conversion, or struct-typed reflected
// field requests this equality. The runtime type owns its conformance.
struct ErasedArrayItem implements Equatable {
	public var value:Int;
	public function new(value:Int) this.value = value;
	public function equals(other:ErasedArrayItem):Bool return value % 10 == other.value % 10;
}
function erasedOwnerArray():Int {
	var owner = new ArrayEqualityOwner([new ErasedArrayItem(1), new ErasedArrayItem(11)]);
	var erased:ArrayEqualityOwner<Dynamic> = cast owner;
	var view:Array<Dynamic> = cast erased.value;
	return view.indexOf(view[1]) == 0 ? 42 : 1;
}

function staticCallback():Int return 42;

function main():Int {
	var typedLeft = new SelfMutatingArrayItem(1), typedRight = new SelfMutatingArrayItem(11);
	if (!(typedLeft == typedRight) || typedLeft.value != 1 || typedRight.value != 11
		|| typedLeft.label != "owned" || typedRight.label != "owned") return 26;
	var boxedLeft:Dynamic = typedLeft, boxedRight:Dynamic = typedRight;
	if (!(boxedLeft == boxedRight)) return 27;
	var restoredLeft:SelfMutatingArrayItem = cast boxedLeft, restoredRight:SelfMutatingArrayItem = cast boxedRight;
	if (restoredLeft.value != 1 || restoredRight.value != 11 || restoredLeft.label != "owned" || restoredRight.label != "owned") return 28;
	if (erasedOwnerArray() != 42) return 24;
	var ieee:Dynamic = new IeeeArrayItem(Math.NaN);
	if (ieee == ieee) return 25;
	var interfaceValue:Equatable = new DynamicArrayItem(3);
	var interfaceDynamic:Dynamic = interfaceValue, concreteDynamic:Dynamic = new DynamicArrayItem(13);
	if (interfaceDynamic != concreteDynamic || concreteDynamic != interfaceDynamic) return 29;
	var result = erasedOnly();
	if (result != 0) return result;
	var left:Dynamic = new DynamicArrayItem(5), right:Dynamic = new DynamicArrayItem(15);
	if (!(left == right)) return 4;
	var boxed:Array<Dynamic> = [left, right];
	if (boxed.indexOf(new DynamicArrayItem(25)) != 0 || !boxed.remove(new DynamicArrayItem(35))) return 5;
	var nullable:Array<Null<DynamicArrayItem>> = [null, new DynamicArrayItem(7), null];
	var view:Array<Dynamic> = cast nullable;
	if (view.indexOf(null) != 0 || view.indexOf(new DynamicArrayItem(17)) != 1) return 6;
	if (!view.remove(new DynamicArrayItem(27)) || nullable.length != 2 || nullable[0] != null || nullable[1] != null) return 7;
	var reflectedLeft:Dynamic = Reflect.field(new ReflectedArrayOwner(4), "item");
	var reflectedRight:Dynamic = Reflect.field(new ReflectedArrayOwner(14), "item");
	if (!(reflectedLeft == reflectedRight)) return 8;
	MutationFixture.prepare();
	if (MutationFixture.items.remove(new MutatingArrayItem(2))) return 9;
	if (MutationFixture.items.length != 1 || MutationFixture.items[0].value != 1) return 10;
	MutationFixture.prepare();
	var mutatingView:Array<Dynamic> = cast MutationFixture.items;
	if (mutatingView.remove(new MutatingArrayItem(2))) return 11;
	if (MutationFixture.items.length != 1 || MutationFixture.items[0].value != 1) return 12;
	var nonconforming:Dynamic = Reflect.field(new NonEquatableOwner(), "item"), rejected = false;
	try { if (nonconforming == nonconforming) return 13; } catch (_:Dynamic) rejected = true;
	if (!rejected) return 14;
	var callback:Dynamic = staticCallback;
	if (callback != callback) return 15;
	var number:Dynamic = 7, anotherNumber:Dynamic = 7;
	if (number != anotherNumber || number == left) return 16;
	if (left == reflectedLeft || reflectedLeft == left) return 17;
	var collisionA:Dynamic = new CaxscQFXbw(1), collisionB:Dynamic = new CVqowVrIwv(1);
	if (collisionA == collisionB || collisionB == collisionA) return 18;
	var optionalLeft:Dynamic = new OptionalArrayItem(new DynamicArrayItem(3));
	var optionalRight:Dynamic = new OptionalArrayItem(new DynamicArrayItem(13));
	if (optionalLeft != optionalRight) return 19;
	MutationFixture.prepare();
	MutationFixture.shrink = false;
	MutationFixture.replace = true;
	if (!MutationFixture.items.remove(new MutatingArrayItem(2)) || MutationFixture.items.length != 1) return 22;
	MutationFixture.prepare();
	MutationFixture.shrink = false;
	MutationFixture.replace = true;
	var replacementView:Array<Dynamic> = cast MutationFixture.items;
	if (!replacementView.remove(new MutatingArrayItem(2)) || MutationFixture.items.length != 1) return 23;
	DynamicArrayEqualityCensus.prepare();
	DynamicArrayEqualityCensus.perform(1);
	for (n in [8, 1024]) {
		#if !wasm
		var before = hl.Gc.totalAllocated();
		#end
		if (DynamicArrayEqualityCensus.perform(n) != 5 * n) return 20;
		#if !wasm
		if (hl.Gc.totalAllocated() != before) return 21;
		#end
	}
	return 42;
}
