// An unannotated field of a generic class is typed with the class's own type parameters, as Haxe types it: `Std.int` of a `T`
// is an error there, though the initializer's type, Int, does not mention T and typing it with T erased to Dynamic accepts it.
class Box<T> {
	public var value:T;
	public var rounded = {var round = (x: T) -> Std.int(x);
	0;
	};

	public function new(value:T) {
		this.value = value;
	}
}

class Main {
	static function main() {
		Sys.println(new Box(1).rounded);
	}
}
