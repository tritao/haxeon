function take(f:Int->Int->Void):Int {
	try {
		f(1, 2);
	} catch (_:Dynamic) {
		return 1;
	}
	return 0;
}

function main():Int {
	var label = "read-only";
	var caught = take((_, _) -> throw label + " value");
	caught += take((a, b) -> throw "contextual Void");
	var typed:Int->Void = _ -> throw "declared Void";
	try
		typed(1)
	catch (_:Dynamic)
		caught++;
	var bare = function():Void throw "no context";
	try
		bare()
	catch (_:Dynamic)
		caught++;
	var valued:Int->Int = x -> throw "Int result";
	try
		valued(1)
	catch (_:Dynamic)
		caught++;
	var inferred = (x:Int) -> x > 0 ? x : throw "negative";
	return caught * 10 + inferred(2);
}
