function main():Int {
	var value = "bananabanana";
	if (value.lastIndexOf("ana") != 9 || value.lastIndexOf("ana", 7) != 7 || value.lastIndexOf("ana", 5) != 3)
		return 1;
	if (value.lastIndexOf("x") != -1 || value.lastIndexOf("", 99) != value.length || value.lastIndexOf("", -1) != -1)
		return 2;
	if ("".lastIndexOf("") != 0)
		return 3;
	if ("Hello, Wasm GC!".toLowerCase() != "hello, wasm gc!")
		return 4;
	if ("Hello, Wasm GC!".toUpperCase() != "HELLO, WASM GC!")
		return 5;
	return 42;
}
