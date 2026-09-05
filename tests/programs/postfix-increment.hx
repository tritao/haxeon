class Counter {
	public static var value:Int = 38;
}

function main():Int {
	var oldStatic = Counter.value++;
	var values = [1];
	var oldIndex = values[0]++;
	var local = 0;
	var oldLocal = local++;
	return oldStatic + oldIndex + oldLocal + local + values[0];
}
