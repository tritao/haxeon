interface Parent<T> {
	function parent():T;
}

interface Source<T> extends Parent<T> {
	function get():T;
}

class Base<T> {
	var value:T;

	public function new(value:T) {
		this.value = value;
	}

	public function getBase():T
		return value;
}

class IntSource extends Base<Int> implements Source<Int> {
	public function new() {
		super(40);
	}

	public function get():Int
		return 2;

	public function parent():Int
		return 40;
}

function read(source:Source<Int>):Int
	return source.get() + source.parent();

function main():Int
	return read(new IntSource());
