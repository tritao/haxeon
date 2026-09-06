interface Source<T> {
	function get():T;
}

class Base<T> {}

class IntSource extends Base<Int> implements Source<Int> {
	public function new() {}

	public function get():Int
		return 42;
}

function read(source:Source<Int>):Int
	return source.get();

function main():Int
	return read(new IntSource());
