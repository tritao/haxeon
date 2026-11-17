// An error in an abstract's instance method is reported although nothing calls the method: Haxe types every member.
abstract Celsius(Float) from Float {
	public function fahrenheit():Float
		return this * 9 / 5 + 32;

	public function label():Float
		return "C";
}

class Main {
	static function main() {
		var c:Celsius = 21.5;
		Sys.println(c.fahrenheit());
	}
}
