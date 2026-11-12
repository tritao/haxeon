enum Q3Ordinary implements Equatable {
	Item(value:Int);
}
enum Q3Custom implements Equatable {

	Item(value:Int);
	public function equals(other:Q3Custom):Bool
		return true;
}
class Q3Identity {
	public function new() {}
}

function main():Int {
	var a:Dynamic = Q3Ordinary.Item(7),
		b:Dynamic = Q3Ordinary.Item(7),
		c:Dynamic = Q3Ordinary.Item(8);
	if (!(a == b) || a == c || !Type.enumEq(a, b) || Type.enumEq(a, c))
		return 1;
	var x:Dynamic = Q3Custom.Item(1), y:Dynamic = Q3Custom.Item(2);
	if (!(x == y) || Type.enumEq(x, y))
		return 2;
	var first:Dynamic = new Q3Identity(),
		alias:Dynamic = first,
		second:Dynamic = new Q3Identity();
	if (!(first == alias) || first == second || first == null || null == first)
		return 3;
	var text:Dynamic = ["a", "b"].join("");
	if (!(text == "ab") || text == "ac")
		return 4;
	var values:Array<Dynamic> = [a, x, first, null];
	if (!values.contains(b) || !values.contains(y) || values.contains(second) || !values.contains(null))
		return 5;
	return 42;
}
