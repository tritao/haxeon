function identity<T>(value:T):T
	return value;

function first<T>(values:Array<T>):T
	return values[0];

class GenericMath {
	public static function choose<T>(left:T, right:T):T
		return left;
}

function main():Int {
	identity("specialized independently");
	var values = new Array<Int>(1);
	values[0] = 40;
	return GenericMath.choose(first(values), identity(1)) + identity(2);
}
