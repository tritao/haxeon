class Main {
	static function fib(n:Int):Int {
		if (n <= 1)
			return n;
		return fib(n - 1) + fib(n - 2);
	}

	static function main():Void {
		Sys.exit(fib(10));
	}
}
