abstract Identity<T>(T) from T to T {
	public function new(value:T) {
		this = value;
	}

	public static function wrap(value:T):Identity<T>
		return value;

	public function unwrap():T
		return this;
}

function read(value:Identity<Int>):Int
	return value;

function main():Int
	return read(Identity.wrap(42)) + new Identity<Int>(0).unwrap();
