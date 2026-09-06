interface Readable {
	function read():Int;
}

class Value implements Readable {
	public function new() {}

	public function read():Int
		return 42;
}

function consume<T:Readable>(value:T):Int
	return value.read();

function main():Int
	return consume(new Value());
