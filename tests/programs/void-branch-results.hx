enum Setting { Flag(value:Bool); Count(value:Int); }

class Store {
	public var flags = 0;
	public var counts = 0;

	public function new() {}

	public function setFlag(value:Bool):Bool {
		flags++;
		return value;
	}

	public function setCount(value:Int):Int {
		counts += value;
		return counts;
	}
}

// Void callbacks may end in switch or conditional branches whose values are discarded.
function main():Int {
	var store = new Store();
	var apply:Setting->Void = function(setting) switch (setting) {
		case Flag(value): store.setFlag(value);
		case Count(value): store.setCount(value);
	};
	var toggle:Bool->Void = function(on) on ? store.setFlag(on) : store.setCount(1);
	apply(Flag(true));
	apply(Count(3));
	toggle(true);
	toggle(false);
	return store.flags == 2 && store.counts == 4 ? 42 : 1;
}
