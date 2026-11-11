function options(arguments:Array<Dynamic>):Dynamic
	return arguments.length == 0 || arguments[0] == null ? {} : arguments[0];

function main():Int {
	var empty = options([]), given = options([{answer: 40}]);
	Reflect.setField(empty, "extra", 2);
	return Std.int(Reflect.field(given, "answer")) + Std.int(Reflect.field(empty, "extra"));
}
