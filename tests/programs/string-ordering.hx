class OrderProbe {
	public static var calls:String = "";

	public static function value(tag:String, text:String):String {
		calls += tag;
		return text.substr(0);
	}
}

function main():Int {
	var a = "alpha".substr(0), b = "beta".substr(0);
	if (!(a < b) || !(a <= b) || a > b || a >= b || !(a <= a) || !(a >= a))
		return 1;
	if (!("" < a) || !("al" < a) || !("é" > "z") || !("β" > "é"))
		return 2;
	if (!(OrderProbe.value("L", "z") > OrderProbe.value("R", "a")) || OrderProbe.calls != "LR")
		return 3;
	OrderProbe.calls = "";
	if (!(OrderProbe.value("L", "a") <= OrderProbe.value("R", "z")) || OrderProbe.calls != "LR")
		return 4;
	return 42;
}
