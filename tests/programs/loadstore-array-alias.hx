class ArrayAliasCheck {
	static function observe(a:Array<Int>, b:Array<Int>, i:Int, j:Int):Int {
		var before = a[i];
		b[j] = 39;
		return before + a[i];
	}

	public static function check():Int {
		var a = [3, 9];
		return observe(a, a, 0, 0);
	}
}

function main():Int
	return ArrayAliasCheck.check();
