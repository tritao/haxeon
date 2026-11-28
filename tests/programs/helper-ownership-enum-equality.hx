// The equality helper of Color is requested from a generic method and from a plain function.
enum Color implements Equatable {

	Red;
	Green;
	Mixed(amount:Int);
}
class Compare<T:Equatable> {
	public function new() {}

	public function same(left:T, right:T):Bool
		return left == right;
}

function plain(left:Color, right:Color):Bool
	return left == right;

function main():Int {
	var compare = new Compare<Color>();
	if (!compare.same(Mixed(2), Mixed(2)) || compare.same(Red, Green))
		return 1;
	return plain(Mixed(3), Mixed(3)) && !plain(Red, Mixed(1)) ? 42 : 2;
}
