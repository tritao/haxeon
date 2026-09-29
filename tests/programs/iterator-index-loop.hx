function main():Int {
	var values:Array<Int> = [1, 2, 3, 4];
	var total = 0;
	for (value in values.iterator())
		total += value; // 10
	var map:Map<String, Int> = new Map();
	map.set("a", 5);
	map.set("b", 7);
	var keyLength = 0;
	for (key in map.keys())
		keyLength += key.length; // 2
	var mapTotal = 0;
	for (value in map.values())
		mapTotal += value; // 12
	for (value in map.iterator())
		mapTotal += value; // 24
	var doubled = [for (value in values.iterator()) value * 2]; // 8 doubled length 4
	var evenKeys = [for (key in map.keys()) key + "!"]; // length 2
	// 10 + 2 + 24 + 4 + 2 = 42
	return total + keyLength + mapTotal + doubled.length + evenKeys.length;
}
