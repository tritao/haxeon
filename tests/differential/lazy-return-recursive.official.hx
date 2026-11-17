class Main {
	static function power(n:Int) return if (n == 0) 1 else power(n - 1) * 2;

	static function fib(n:Int) {
		if (n < 2)
			return n;
		return fib(n - 1) + fib(n - 2);
	}

	static function isEven(n:Int):Bool return n == 0 ? true : isOdd(n - 1);

	static function isOdd(n:Int) return n == 0 ? false : isEven(n - 1);

	static function countDown(n:Int, out:Array<Int>) {
		if (n < 0)
			return;
		out.push(n);
		countDown(n - 1, out);
	}

	static function main() {
		Sys.println(power(10));
		Sys.println(fib(15));
		Sys.println(isEven(10) + " " + isOdd(7));
		var out = [];
		countDown(3, out);
		Sys.println(out);
	}
}
