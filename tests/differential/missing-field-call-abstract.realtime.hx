// A method an abstract value does not have is missing from the abstract, as Haxe reports it.
abstract Meters(Float) {
	public function new(value:Float)
		this = value;
}

class Main {
	static function main() {
		var length = new Meters(2);
		length.toFeet();
	}
}
