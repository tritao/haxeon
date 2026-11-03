function main():Int {
	var first:Map<String, Bool> = new Map(), second:Map<String, Bool> = new Map();
	first["first"] = true;
	second["second"] = true;
	var outer:Map<String, Map<String, Bool>> = new Map();
	outer["a"] = first;
	outer["b"] = second;
	var direct = 0, explicit = 0, iterator = 0;
	for (value in outer) {
		if (value.exists("first")) direct += 10;
		if (value.exists("second")) direct += 11;
	}
	for (value in outer.values()) {
		if (value.exists("first")) explicit += 4;
		if (value.exists("second")) explicit += 6;
	}
	for (value in outer.iterator()) {
		if (value.exists("first")) iterator += 5;
		if (value.exists("second")) iterator += 6;
	}
	var names:Map<String, String> = new Map();
	names["name"] = "ready";
	var found = false;
	for (value in names) if (value == "ready") found = true;
	if (!found) return 1;
	return direct + explicit + iterator;
}
