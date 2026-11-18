// String keys match by content, never by the String object: keys built at run time find entries set with literals, and
// keys that are prefixes of one another, or share a hash bucket, stay distinct.
function build(parts:Array<String>):String {
	var text = "";
	for (part in parts)
		text += part;
	return text;
}

function main():Int {
	var values = new Map<String, Int>();
	values.set("ab", 1);
	values.set("abc", 2);
	values.set("a", 3);
	values.set("", 4);
	if (values.get(build(["a", "b"])) != 1 || values.get(build(["a", "b", "c"])) != 2 || values.get(build(["a"])) != 3
		|| values.get(build([])) != 4)
		return 1;
	if (values.exists("abcd") || values.exists("b") || values.get("ab".substr(0, 1)) != 3)
		return 2;
	values.set(build(["a", "bc"]), 20);
	if (values.get("abc") != 20 || values.size() != 4)
		return 3;
	if (!values.remove(build(["a", "b"])) || values.exists("ab") || values.get("abc") != 20)
		return 4;

	// Past the small-map limit, through several rebuilds, every key still finds its own entry.
	var many = new Map<String, Int>();
	for (i in 0...3000)
		many.set("key" + i, i);
	for (i in 0...3000)
		if (many.get(build(["key", Std.string(i)])) != i)
			return 5;
	for (i in 0...3000)
		if (i % 2 == 0 && !many.remove("key" + i))
			return 6;
	var count = 0;
	for (key in many.keys()) {
		if (many.get(key) != Std.parseInt(key.substr(3)))
			return 7;
		count++;
	}
	if (count != 1500 || many.exists("key0") || many.get("key1") != 1)
		return 8;
	return 42;
}
