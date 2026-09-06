interface Readable {
	function read():Int;
}

interface Writable {
	function write():Int;
}

class Value implements Readable, Writable {
	public function new() {}
	public function read():Int
		return 42;
	public function write():Int
		return 0;
}
class Holder<T:(Readable, Writable)> {
	public function new() {}
}

function consume<T:(Readable, Writable)>(value:T):Int
	return value.read() + value.write();

function main():Int {
	var holder:Holder<Value> = new Holder<Value>();
	return consume(new Value());
}
