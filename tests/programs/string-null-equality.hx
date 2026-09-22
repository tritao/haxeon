function same(left:String, right:String):Bool {
	return left == right;
}

function different(left:String, right:String):Bool {
	return left != right;
}

function defaulted(?value:String):String {
	return value == null ? "fallback" : value;
}

function main():Int {
	if (!same(null, null))
		return 1;
	if (same(null, "") || same("", null))
		return 2;
	if (same(null, "null") || same("null", null))
		return 3;
	if (same(null, "value") || same("value", null))
		return 4;
	if (!same("", "") || !same("value", "value"))
		return 5;
	if (same("value", "other") || same("", "value"))
		return 6;
	if (!different(null, "") || !different("", null))
		return 7;
	if (different(null, null) || different("", ""))
		return 8;
	if (defaulted() != "fallback" || defaulted("") != "")
		return 9;
	return 42;
}
