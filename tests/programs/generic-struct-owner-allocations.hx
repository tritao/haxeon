interface AllocationMeasured {
	function measure():Int;
}

class AllocationOwner {
	public function new() {}
}

struct AllocationValue implements AllocationMeasured {
	public var number:Int;
	public var owner:AllocationOwner;
	public function new(number:Int, owner:AllocationOwner) { this.number = number; this.owner = owner; }
	public function measure():Int return number;
}

class AllocationBox<T> {
	public var value:T;
	public function new(value:T) this.value = value;
	public function get():T return value;
	public function set(value:T):Void this.value = value;
}

class AllocationClosure {
	public static var read:Void->AllocationValue;
	public static var number:AllocationValue->Int;
	public static function extract(value:AllocationValue):Int return value.number;
}

class AllocationMeter<T:AllocationMeasured> {
	public var value:T;
	public function new(value:T) this.value = value;
	public function measure():Int return value.measure();
}

class AllocationCensus {
	static var owner:AllocationOwner;
	static var meter:AllocationMeter<AllocationValue>;
	public static function prepare():Void {
		owner = new AllocationOwner();
		meter = new AllocationMeter<AllocationValue>(new AllocationValue(0, owner));
	}
	public static function perform(n:Int):Int {
		var total = 0;
		for (index in 0...n) {
			meter.value = new AllocationValue(index, owner);
			total += meter.measure();
		}
		return total;
	}
}

function main():Int {
	var owner = new AllocationOwner();
	var values = [new AllocationValue(1, owner), new AllocationValue(2, owner)];
	var popped = values.pop();
	if (popped.number != 2 || popped.owner != owner || values[0].number != 1) return 11;
	var box = new AllocationBox<AllocationValue>(new AllocationValue(0, owner));
	var meter = new AllocationMeter<AllocationValue>(new AllocationValue(0, owner));
	AllocationClosure.read = box.get;
	AllocationClosure.number = AllocationClosure.extract;
	var read = AllocationClosure.read;
	var number = AllocationClosure.number;
	var escaped:Dynamic = read;
	if (escaped == null) return 4;
	var escapedValue:AllocationValue = cast escaped();
	if (escapedValue.number != 0 || escapedValue.owner != owner) return 5;
	var restored:Void->AllocationValue = cast escaped;
	if (restored().owner != owner) return 8;
	var escapedNumber:Dynamic = number;
	if (escapedNumber(new AllocationValue(17, owner)) != 17) return 6;
	var interfaceValue:AllocationMeasured = new AllocationValue(19, owner);
	if (escapedNumber(interfaceValue) != 19) return 12;
	var rejected = false;
	try escapedNumber("wrong") catch (_:Dynamic) rejected = true;
	if (!rejected) return 13;
	var restoredNumber:AllocationValue->Int = cast escapedNumber;
	if (restoredNumber(new AllocationValue(18, owner)) != 18) return 9;
	var absent:Void->AllocationValue = null;
	var erasedAbsent:Dynamic = absent;
	if (erasedAbsent != null) return 7;
	var restoredAbsent:Void->AllocationValue = cast erasedAbsent;
	if (restoredAbsent != null) return 10;
	read();
	#if !wasm
	var before = hl.Gc.totalAllocated();
	#end
	var total = 0;
	for (index in 0...1024) {
		box.value = new AllocationValue(index, owner);
		var value = box.value;
		if (value.owner != owner) return 1;
		total += number(value);
	}
	if (total != 523776) return 3;
	#if !wasm
	var fieldAllocated = hl.Gc.totalAllocated() - before;
	before = hl.Gc.totalAllocated();
	#end
	total = 0;
	for (index in 0...1024) {
		box.set(new AllocationValue(index, owner));
		var value = box.get();
		if (value.owner != owner) return 1;
		total += value.number;
	}
	if (total != 523776) return 3;
	#if !wasm
	var directAllocated = hl.Gc.totalAllocated() - before;
	before = hl.Gc.totalAllocated();
	#end
	total = 0;
	for (index in 0...1024) {
		box.set(new AllocationValue(index, owner));
		var value = read();
		if (value.owner != owner) return 1;
		total += value.number;
	}
	#if !wasm
	var closureAllocated = hl.Gc.totalAllocated() - before;
	before = hl.Gc.totalAllocated();
	#end
	var measuredTotal = 0;
	for (index in 0...1024) {
		meter.value = new AllocationValue(index, owner);
		measuredTotal += meter.measure();
	}
	#if !wasm
	var measuredAllocated = hl.Gc.totalAllocated() - before;
	if (fieldAllocated != 0 || directAllocated != 0 || closureAllocated != 0 || measuredAllocated != 0) {
		Sys.println('generic owner allocations: field=$fieldAllocated direct=$directAllocated closure=$closureAllocated constrained=$measuredAllocated bytes');
		return 2;
	}
	#end
	return total == 523776 && measuredTotal == 523776 ? 42 : 3;
}
