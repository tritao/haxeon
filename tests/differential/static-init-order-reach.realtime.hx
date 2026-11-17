// What a class's static initialization reaches, which places the classes it reaches first (Haxe's sort_types): lambdas written
// inside an initializer and the static methods it calls are followed; a static initialized with a lambda is followed only where it
// is read; instance methods, overriding ones included, are not.
class Main {
	static function main() {
		var stored = StoredCallback.callback;
		Sys.println(stored());
		Sys.println(NestedLambda.value + " " + NestedLambdaTarget.value);
		Sys.println(ReadCallback.value);
		Sys.println(Overriding.value);
		Sys.println(InstanceMethod.value);
		Sys.println(Mutual.x * 100 + MutualTarget.x);
		Sys.println(SelfRead.x);
	}
}

class StoredCallback {
	public static final callback:() -> Int = () -> StoredCallbackTarget.value;
}

class StoredCallbackTarget {
	public static final value:Int = StoredCallback.callback == null ? 0 : 7;
}

class NestedLambda {
	public static final value:Int = store(() -> NestedLambdaTarget.value, 0) + 7;

	static function store(f:() -> Int, depth:Int):Int
		return depth <= 0 ? 0 : store(f, depth - 1);
}

class NestedLambdaTarget {
	public static final value:Int = NestedLambda.value;
}

class ReadCallback {
	public static final callback:() -> Int = () -> ReadCallbackTarget.value;
	public static final value:Int = invoke();

	static function invoke():Int {
		var f = callback;
		return f();
	}
}

class ReadCallbackTarget {
	public static final value:Int = 7;
}

class Overriding {
	public static final value:Int = read(new OverridingChild());

	static function read(base:OverridingBase):Int
		return base.get();
}

class OverridingBase {
	public function new() {}

	public function get():Int
		return 0;
}

class OverridingChild extends OverridingBase {
	public function new()
		super();

	override public function get():Int
		return OverridingTarget.value;
}

class OverridingTarget {
	public static final value:Int = 7;
}

class InstanceMethod {
	public static final value:Int = new InstanceMethodHolder().get();
}

class InstanceMethodHolder {
	public function new() {}

	public function get():Int
		return InstanceMethodTarget.value;
}

class InstanceMethodTarget {
	public static final value:Int = 7;
}

class Mutual {
	public static final x:Int = MutualTarget.x + 7;
}

class MutualTarget {
	public static final x:Int = Mutual.x + 1;
}

class SelfRead {
	public static final x:Int = x + 1;
}
