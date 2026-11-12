// A method call on a class nothing constructs: the call is reachable, so the class keeps the method it names (the verifier resolves the
// call against that class's table) even though no instance can exist.
class Base {
	public function new() {}
	public function update():Int return 1;
	public function untouched():Int return 2;
}

function callThrough(receiver:Null<Base>):Int
	return receiver == null ? 0 : receiver.update();

function main():Int {
	var none:Null<Base> = null;
	return callThrough(none) == 0 ? 42 : 1;
}
