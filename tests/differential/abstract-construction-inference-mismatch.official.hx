// A generic abstract's type arguments come from the constructor's arguments, not the expected type: `new Box([1, 2])` is a
// Box<Int>, which is no Box<Float> ("Int should be Float"), as in Haxe.
abstract Box<T>(Array<T>) {
	public function new(values:Array<T>)
		this = values;
}

class Main {
	static function main() {
		var floats:Box<Float> = new Box([1, 2]);
	}
}
