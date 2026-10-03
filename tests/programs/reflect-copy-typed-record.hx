typedef Snapshot = {
	var flag:Null<Bool>;
	final base:Null<String>;
	final items:Array<Int>;
}

function main():Int {
	var original:Snapshot = {flag: false, base: null, items: [7]};
	var copied:Snapshot = cast Reflect.copy(original);
	if (copied.flag != false || copied.base != null || copied.items[0] != 7)
		return 1;
	copied.flag = true;
	if (original.flag != false)
		return 2;
	copied.items[0] = 9;
	if (original.items[0] != 9)
		return 3;
	return Reflect.copy(null) == null ? 42 : 4;
}
