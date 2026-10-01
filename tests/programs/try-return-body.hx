// A try whose body is a bare `return`, with no braces and no semicolon before its catch.
class Main {
	static function pick(fail:Bool):{value:Int} {
		try
			return {value: compute(fail)} catch (error:Dynamic)
			return {value: 2};
	}

	static function compute(fail:Bool):Int {
		if (fail)
			throw "no";
		return 40;
	}

	static function main() {
		Sys.exit(pick(false).value + pick(true).value);
	}
}
