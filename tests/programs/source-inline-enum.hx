enum Packet {
	Empty;
	Code(value:Int);
	Text(value:String, owner:Owner);
	Decimal(value:Float);
	Bit(value:Bool);
}

enum Nested {
	Wrapped(value:Packet);
}

class Owner {
	public var code:Int;

	public function new(code:Int)
		this.code = code;
}

class Slot {
	public var value:Null<Packet>;

	public function new() {}
}

class EnumCensus {
	static final owner = new Owner(40);
	static final text = "ok";
	static var saved:Null<Packet>;
	static final slot = new Slot();
	static final callback:Void->Null<Packet> = () -> slot.value;
	static var root:Null<Packet>;
	static final rootSlot = new Slot();
	static var rootArray:Array<Packet>;

	@:expose public static function prepareRoots():Void {
		root = Text(text, new Owner(40));
		rootSlot.value = Text(text, new Owner(40));
		rootArray = [Text(text, new Owner(40))];
	}

	@:expose public static function checkRoots():Int {
		for (value in [root, rootSlot.value, rootArray[0]]) {
			if ((switch value {
				case Text(label, reference): reference.code + label.length;
				default: -1;
			}) != 42)
				return -1;
		}
		return 42;
	}

	static final values:Array<Packet> = [Code(1), Text(text, owner), Empty];

	static function choose(flag:Bool, value:Packet):Null<Packet>
		return flag ? value : null;

	static function score(value:Null<Packet>):Int {
		if (value == null)
			return 0;
		return switch value {
			case Code(code): code;
			case Text(text, reference): reference == owner ? reference.code + text.length : -100;
			case Decimal(number): number == 42.5 ? 42 : -1;
			case Bit(flag): flag ? 42 : -1;
			case Empty: 0;
		};
	}

	@:expose public static function perform(count:Int):Int {
		var sum = 0;
		for (index in 0...count) {
			var first:Packet = Text(text, owner);
			var copy = first;
			first = Code(-1);
			saved = choose(true, copy);
			slot.value = saved;
			saved = null;
			var call = callback;
			sum += score(call());
			if (score(choose(false, copy)) != 0 || score(first) != -1)
				return -1;
		}
		return sum;
	}

	public static function arrays():Bool {
		var created = new Array<Packet>();
		created.push(Decimal(42.5));
		created.push(Bit(true));
		if (score(created[0]) != 42 || score(created[1]) != 42)
			return false;
		var optionals:Array<Null<Packet>> = [null, Text(text, owner)];
		if (score(optionals[0]) != 0 || score(optionals[1]) != 42)
			return false;
		var nested = Wrapped(optionals[1]);
		if ((switch nested {
			case Wrapped(value): score(value);
		}) != 42)
			return false;
		var copy = values[1];
		values[1] = Code(9);
		if (score(copy) != 42)
			return false;
		values[1] = copy;
		var sum = 0;
		for (value in values.iterator())
			sum += score(value);
		return sum == 43;
	}
}

function main():Int {
	EnumCensus.prepareRoots();
	#if !wasm
	hl.Gc.major();
	#end
	if (EnumCensus.checkRoots() != 42)
		return 3;
	if (!EnumCensus.arrays() || EnumCensus.perform(8) != 336)
		return 1;
	#if !wasm
	for (count in [8, 1024]) {
		hl.Gc.censusStart(0);
		var before = hl.Gc.totalAllocated();
		var result = EnumCensus.perform(count);
		var allocated = hl.Gc.totalAllocated() - before;
		hl.Gc.censusStop();
		if (result != 42 * count || allocated != 0)
			return 2;
	}
	#end
	return 42;
}
