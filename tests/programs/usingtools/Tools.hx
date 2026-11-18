package usingtools;

// Three holders of `tag`: a `using` of this module tries its last type first and the module's own functions last.
class First {
	public static function tag(x:Int):Int
		return 1;

	public static function onlyFirst(x:Int):Int
		return 10;
}

class Second {
	public static function tag(x:Int):Int
		return 2;
}

// A private type of the module is not brought in.
private class Hidden {
	public static function secret(x:Int):Int
		return 99;
}

function tag(x:Int):Int
	return 3;

function moduleOnly(x:Int):Int
	return 4;
