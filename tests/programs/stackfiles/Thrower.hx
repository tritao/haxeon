package stackfiles;

class Thrower {
	public static function fail(depth:Int):Int {
		if (depth > 2)
			throw 'failed at $depth';
		return fail(depth + 1) + 1;
	}
}
