class Counter {
	final start:Int;
	public final initial:Int;

	public function new(start:Int) {
		this.start = start;
		initial = read();
	}

	public dynamic function read():Int {
		return this.start;
	}

	public function replace(other:Counter):Void {
		other.read = () -> this.start + 10;
	}
}

class DerivedCounter extends Counter {
	public function new(start:Int) {
		super(start);
	}

	override public function read():Int {
		return 7;
	}
}

class Main {
	static final initialAnswer = answer();

	static dynamic function answer():Int {
		return 3;
	}

	static function invoke(callback:Void->Int):Int {
		return callback();
	}

	static function main():Void {
		var source = new Counter(20);
		var target = new Counter(2);
		var concrete = new DerivedCounter(1);
		var derived:Counter = concrete;
		var original = target.read;
		var originalAnswer = Main.answer;
		if (source.read() != 20 || original() != 2 || invoke(derived.read) != 7 || concrete.initial != 7
			|| concrete.read() != 7 || initialAnswer != 3 || answer() != 3)
			Sys.exit(1);

		source.replace(target);
		Main.answer = () -> 12;
		derived.read = () -> 9;
		if (invoke(target.read) != 30 || original() != 2 || concrete.read() != 9 || source.read() != 20
			|| originalAnswer() != 3 || Main.answer() + target.read() != 42)
			Sys.exit(2);

		var reflected:Void->Int = Reflect.field(target, "read");
		if (reflected() != 30)
			Sys.exit(3);
		Reflect.setField(target, "read", () -> 42);
		Sys.exit(target.read());
	}
}
