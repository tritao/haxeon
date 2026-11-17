class Main {
	static function value(flag:Bool) {
		if (flag)
			return 1;
		return 1.5;
	}

	static function main() {
		Sys.println(value(true));
	}
}
