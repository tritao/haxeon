interface Service {
	public function value(required:Int, ?suffix:String, ?extra:Int):Int;
}

interface Derived extends Service {}

class Impl implements Derived {
	public function new() {}

	public function value(required:Int, ?suffix:String, ?extra:Int):Int
		return required + (suffix == null ? 2 : suffix.length) + (extra == null ? 0 : extra);
}

function main():Int {
	var service:Service = new Impl();
	if (service.value(40) != 42)
		return 1;
	if (service.value(40, "ab") != 42)
		return 2;
	if (service.value(39, null, 1) != 42)
		return 3;
	var derived:Derived = new Impl();
	if (derived.value(40) != 42)
		return 4;
	return 42;
}
