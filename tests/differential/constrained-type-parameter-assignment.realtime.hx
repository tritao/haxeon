// A value whose type is a constrained type parameter is a value of each of its constraints, as Haxe unifies it: stored in an
// array of the constraint, passed and returned as it, assigned to a variable of it, in a function nothing calls as well.
interface Resource {
	function close():Int;
}

class Base {
	public function new() {}

	public function id():Int
		return 1;
}

class Handle extends Base implements Resource {
	public function new()
		super();

	public function close():Int
		return 7;
}

class Pool {
	public final resources:Array<Resource> = [];

	public function new() {}

	public function keep < T:Resource > (resource:T):T {
		resources.push(resource);
		return resource;
	}
}

class Main {
	static function asResource < T:Resource > (value:T):Resource return value;

	static function asBase < T:Base > (value:T):Int {
		var base:Base = value;
		return base.id();
	}

	static function closeAll < T:Resource > (values:Array<T>):Int {
		var total = 0;
		for (value in values) {
			var resource:Resource = value;
			total += resource.close();
		}
		return total;
	}

	static function unused < T:Resource > (value:T):Array<Resource> return [value];

	static function main() {
		var pool = new Pool();
		Sys.println(pool.keep(new Handle()).id());
		Sys.println(pool.resources.length);
		Sys.println(asResource(new Handle()).close());
		Sys.println(asBase(new Handle()));
		Sys.println(closeAll([new Handle(), new Handle()]));
	}
}
