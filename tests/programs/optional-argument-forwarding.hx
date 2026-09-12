class Main {
	static function inner(?value:Int):Int
		return value == null ? 42 : value;

	static function outer(?value:Int):Int
		return inner(value);

	static function main():Int
		return outer();
}
