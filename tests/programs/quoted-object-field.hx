function main():Int {
	var value:Dynamic = {version: 1, "package": {name: "a"}, "x-y": 40};
	var quoted:Dynamic = {"first": 1};
	var name:String = Reflect.field(Reflect.field(value, "package"), "name");
	return name == "a" ? Std.int(Reflect.field(value, "x-y")) + Std.int(Reflect.field(value, "version")) + Std.int(Reflect.field(quoted, "first")) : 1;
}
