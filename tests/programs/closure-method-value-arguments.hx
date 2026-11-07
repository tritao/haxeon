enum CallbackValue {
	Number(value:Int, label:String);
}

struct CallbackRecord {
	public var value:Int;
	public var label:String;
	public function new(value:Int, label:String) {
		this.value = value;
		this.label = label;
	}
}
interface CallbackRelay {
	function enums(callback:CallbackValue->Int, count:Int):Int;
	function records(callback:CallbackRecord->Int, count:Int):Int;
}

class BaseRelay implements CallbackRelay {
	public function new() {}

	public function enums(callback:CallbackValue->Int, count:Int):Int {
		var sum = 0;
		for (_ in 0...count)
			sum += callback(Number(40, CallbackMethodCensus.label));
		return sum;
	}

	public function records(callback:CallbackRecord->Int, count:Int):Int {
		var sum = 0;
		for (_ in 0...count)
			sum += callback(new CallbackRecord(40, CallbackMethodCensus.label));
		return sum;
	}
}

class InheritedRelay extends BaseRelay {
	public function new()
		super();
}

class OverridingRelay extends BaseRelay {
	public function new()
		super();

	public override function enums(callback:CallbackValue->Int, count:Int):Int
		return super.enums(callback, count);

	public override function records(callback:CallbackRecord->Int, count:Int):Int
		return super.records(callback, count);
}

class CallbackMethodCensus {
	public static final label = "ok";
	static final plain:Dynamic = function(value:Int):Int return value;

	public static function checkPlain():Bool {
		var call:Int->Int = cast plain;
		return call(42) == 42;
	}

	static final inherited = new InheritedRelay();
	static final overriding = new OverridingRelay();
	static final first:CallbackRelay = inherited;
	static final second:CallbackRelay = overriding;
	static final enumReader:CallbackValue->Int = makeReader();
	static final recordReader:CallbackRecord->Int = value -> value.value + value.label.length;

	static function makeReader():CallbackValue->Int {
		var bias = 0;
		return value -> switch value {
			case Number(number, text): number + text.length + bias;
		};
	}

	@:expose public static function enums(count:Int):Int {
		var read = enumReader;
		return first.enums(read, count) + second.enums(read, count);
	}

	@:expose public static function records(count:Int):Int {
		var read = recordReader;
		return first.records(read, count) + second.records(read, count);
	}

	@:expose public static function concrete(count:Int):Int {
		var read = enumReader;
		return inherited.enums(read, count) + overriding.enums(read, count);
	}
}

function main():Int {
	if (!CallbackMethodCensus.checkPlain())
		return 3;
	if (CallbackMethodCensus.enums(8) != 672 || CallbackMethodCensus.records(8) != 672 || CallbackMethodCensus.concrete(8) != 672)
		return 1;
	#if !wasm
	for (count in [8, 1024]) {
		hl.Gc.censusStart(0);
		var before = hl.Gc.totalAllocated();
		var total = CallbackMethodCensus.enums(count) + CallbackMethodCensus.records(count) + CallbackMethodCensus.concrete(count);
		var allocated = hl.Gc.totalAllocated() - before;
		hl.Gc.censusStop();
		if (total != 252 * count || allocated != 0)
			return 2;
	}
	#end
	return 42;
}
