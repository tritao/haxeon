class ArgumentOwner {
	public var id:Int;
	public function new(id:Int) this.id = id;
}

struct ArgumentValue {
	public var number:Int;
	public var owner:ArgumentOwner;
	public function new(number:Int, owner:ArgumentOwner) { this.number = number; this.owner = owner; }
	public function bump():Int { number += 1; return number; }
}

class ArgumentHolder {
	public var value:ArgumentValue;
	public function new(value:ArgumentValue) this.value = value;
}

class ArgumentState {
	public static var holder:ArgumentHolder;
	public static var escaped:Dynamic;
	public static function mutate():ArgumentValue {
		var owner = holder.value.owner;
		holder.value = new ArgumentValue(30, owner);
		return new ArgumentValue(7, owner);
	}
}

function argumentTotal(first:ArgumentValue, second:ArgumentValue):Int {
	return first.number + second.number + first.owner.id + second.owner.id;
}

function escapeArgument(value:ArgumentValue):Int {
	ArgumentState.escaped = value;
	return value.number;
}

class ValueArgumentCensus {
	static var first:ArgumentValue;
	static var second:ArgumentValue;
	public static function prepare():Void {
		var owner = new ArgumentOwner(2);
		first = new ArgumentValue(20, owner);
		second = new ArgumentValue(18, owner);
	}
	public static function perform(count:Int):Int {
		var total = 0;
		for (_ in 0...count) total += argumentTotal(first, second);
		return total;
	}
}

function main():Int {
	var owner = new ArgumentOwner(2);
	ArgumentState.holder = new ArgumentHolder(new ArgumentValue(10, owner));
	if (argumentTotal(ArgumentState.holder.value, ArgumentState.mutate()) != 21) return 1;
	if (ArgumentState.holder.value.number != 30) return 2;
	var local = new ArgumentValue(1, owner);
	if (local.bump() != 2 || local.bump() != 3 || local.number != 3) return 3;
	if (escapeArgument(local) != 3) return 4;
	local.number = 99;
	var saved:ArgumentValue = cast ArgumentState.escaped;
	if (saved.number != 3 || saved.owner != owner) return 5;
	ValueArgumentCensus.prepare();
	if (ValueArgumentCensus.perform(8) != 336) return 6;
	#if !wasm
	for (count in [8, 1024]) {
		hl.Gc.censusStart(0);
		var before = hl.Gc.totalAllocated(), result = ValueArgumentCensus.perform(count), bytes = hl.Gc.totalAllocated() - before;
		hl.Gc.censusStop();
		if (result != 42 * count || bytes != 0) return 7;
	}
	#end
	return 42;
}
