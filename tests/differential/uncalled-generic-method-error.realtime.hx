// An uncalled generic method of a generic class is typed with its type parameter as itself, which has no fields.
class Box<T> {
	public function new() {}
	public function wrong<U>(value:U):Int
		return value.length;
}
class Main {
	static function main() {}
}
