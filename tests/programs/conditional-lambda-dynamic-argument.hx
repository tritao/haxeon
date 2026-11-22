class Log {
	public static var seen:Array<String> = [];

	public static function record(value:Dynamic):Void
		seen.push("dynamic " + value);

	public static function recordText(text:String):Void
		seen.push("method " + text);
}

// A lambda with a typed argument stands for a function taking Dynamic, as Haxe unifies function arguments the other way
// round; a conditional between the two takes the first branch's type when the second fits it.
function main():Int {
	var seen = Log.seen,
		full = seen.length > 0;
	var lambdaFirst = full ? (text:String) -> seen.push("lambda " + text) : Log.record;
	lambdaFirst("a");
	var lambdaSecond = !full ? Log.record : (text:String) -> seen.push("lambda " + text);
	lambdaSecond(1);
	var expected:String->Void = full ? Log.record : (text:String) -> seen.push("typed " + text);
	expected("b");
	var method = full ? (text:String) -> seen.push("lambda " + text) : Log.recordText;
	method("c");
	var assigned:Dynamic->Void = Log.record;
	assigned = (text:String) -> seen.push("assigned " + text);
	assigned("d");
	return seen.join(",") == "dynamic a,dynamic 1,typed b,method c,assigned d" ? 42 : 1;
}
