import UnconstructedOwned;

// The program uses the interface's record but never opens a handle, so nothing constructs the generated owned-handle wrapper.
// A dynamic `close()` reaches the `close` of the classes the program constructs, not the wrapper's, which would import the
// native destroy function: the module imports nothing.
class Closer {
	public function new() {}

	public function close():Int
		return 40;
}

class Main {
	static function main():Int {
		var value = new uo_value();
		value.set_a(2);
		var closer:Dynamic = new Closer();
		var closed:Int = closer.close();
		return closed + value.get_a();
	}
}
