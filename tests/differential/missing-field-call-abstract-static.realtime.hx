// A static the abstract does not have is missing from `Abstract<Meters>`, as Haxe reports it.
abstract Meters(Float) {
	public function new(value:Float)
		this = value;
}

class Main {
	static function main() {
		Meters.parse("1");
	}
}
