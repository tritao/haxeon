abstract Identity<T>(T) from T to T {
	public static function wrap(value:T):Identity<T>
		return value;
}

function read(value:Identity<Int>):Int
	return value;

function main():Int
	return read(Identity.wrap(42));
