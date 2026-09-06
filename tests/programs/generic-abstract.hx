abstract Identity<T>(T) from T to T {
	public function new(value:T, offset:T) {
		this = value + offset;
	}

	public static function wrap(value:T):Identity<T>
		return value;

	public function unwrap():T
		return this;
}

function read(value:Identity<Int>):Int
	return value;

function main():Int
	return read(Identity.wrap(40)) + new Identity<Int>(1, 1).unwrap();
