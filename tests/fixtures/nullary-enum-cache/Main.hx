enum CacheFlag implements Equatable {
	Off;
	On;
	Payload(value:Int);
	Again(next:CacheFlag);
}

class CacheSlot {
	public var value:CacheFlag;
	public function new(value:CacheFlag) this.value = value;
	public function put(value:CacheFlag):Void this.value = value;
	public function get():CacheFlag return value;
}

class CaseProbe {
	static var holder:Null<CacheSlot>;
	static var values:Null<Array<CacheFlag>>;
	static var garbage:Null<CacheFlag>;

	@:expose public static function prepare():Void {
		holder = new CacheSlot(CacheFlag.Off);
		values = [CacheFlag.Off, CacheFlag.On];
	}

	@:expose public static function clearRoots():Void {
		holder = null;
		values = null;
	}

	@:expose public static function churn(count:Int):Void {
		for (index in 0...count) garbage = CacheFlag.Payload(index);
		garbage = null;
	}

	@:expose public static function perform(count:Int):Int {
		var slot = holder, items = values;
		if (slot == null || items == null) return -1;
		var sum = 0;
		for (index in 0...count) {
			var expected = index & 1;
			var value = expected == 0 ? CacheFlag.Off : CacheFlag.On;
			slot.put(value);
			items[expected] = value;
			if (slot.get() != items[expected] || Type.enumIndex(slot.get()) != expected) return -1;
			switch value {
				case Off: if (expected != 0 || value != CacheFlag.Off) return -1;
				case On: if (expected != 1 || value != CacheFlag.On) return -1;
				case Payload(_) | Again(_): return -1;
			}
			sum += 42;
		}
		return sum;
	}
}

function main():Int {
	CaseProbe.prepare();
	return CaseProbe.perform(2) == 84 ? 42 : 1;
}
