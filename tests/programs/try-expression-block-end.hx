function fail():Int {
	throw "failure";
}

function risky(fail:Bool):Int {
	if (fail)
		throw "failed";
	return 5;
}

function main():Int {
	// A try expression whose catch block ends in a brace needs no semicolon before the next statement, as in Haxe.
	var recovered = try risky(true) catch (error:String) {
		30;
	}
	var total = recovered + try risky(false) catch (error:Dynamic) {
		0;
	}
	// A body that never returns leaves the expression's type to its catch.
	var fallback = try fail() catch (error:String) 7;
	return total + fallback;
}
