function main():Int {
	var integers:Map<String, Int> = [];
	integers.set("zero", 0);
	var missingInteger:Null<Int> = integers.get("missing");
	var storedInteger:Null<Int> = integers.get("zero");
	if (missingInteger != null || storedInteger == null || storedInteger != 0)
		return 0;

	var booleans:Map<Int, Bool> = [];
	booleans.set(1, false);
	var missingBoolean:Null<Bool> = booleans.get(2);
	var storedBoolean:Null<Bool> = booleans.get(1);
	if (missingBoolean != null || storedBoolean == null || storedBoolean)
		return 0;

	return 42;
}

