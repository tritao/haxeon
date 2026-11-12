import compiler.tools.WholeNumber;

class WholeNumberMain {
	static function check(value:Float, expected:String):Void {
		var actual = WholeNumber.text(value);
		if (actual != expected)
			throw 'WholeNumber.text($value) is $actual, expected $expected';
	}

	static function main():Void {
		check(0, "0");
		check(1234, "1234");
		check(2147483648.0, "2147483648");
		check(3221225472.0, "3221225472");
		check(-3000000000.0, "-3000000000");
		check(647995548.4, "647995548");
		Sys.println("PASS: whole-number counters past 2^31");
	}
}
