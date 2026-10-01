abstract Throwing(Int) {
	public function new()
		this = throw "expected";
}

class Holder {
	public var value:Int = 7;

	public static var shared:Int = 8;

	public function new() {}
}

function main():Int {
	var seen = 0;
	try {
		var value = new Throwing();
		return 1;
	} catch (error:String) {
		if (error != "expected")
			return 2;
		seen++;
	}
	var local = 5;
	try {
		local = throw "local";
	} catch (error:String) {
		if (error != "local")
			return 3;
		seen++;
	}
	if (local != 5)
		return 4;
	var holder = new Holder();
	try {
		holder.value = throw "field";
	} catch (error:String) {
		if (error != "field")
			return 5;
		seen++;
	}
	if (holder.value != 7)
		return 6;
	try {
		Holder.shared = throw "static";
	} catch (error:String) {
		if (error != "static")
			return 7;
		seen++;
	}
	if (Holder.shared != 8)
		return 8;
	var array = [9];
	try {
		array[0] = throw "array";
	} catch (error:String) {
		if (error != "array")
			return 9;
		seen++;
	}
	if (array[0] != 9)
		return 10;
	var map = new Map<String, Int>();
	map.set("key", 10);
	try {
		map["key"] = throw "map";
	} catch (error:String) {
		if (error != "map")
			return 11;
		seen++;
	}
	if (map.get("key") != 10)
		return 12;
	try {
		var never:Int = throw "init";
	} catch (error:String) {
		if (error != "init")
			return 13;
		seen++;
	}
	var capture = function():Void {
		local = throw "captured";
	};
	try {
		capture();
	} catch (error:String) {
		if (error != "captured")
			return 14;
		seen++;
	}
	if (local != 5 || seen != 8)
		return 15;
	return 42;
}
