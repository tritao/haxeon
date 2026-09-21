function main():Int {
	var empty:Dynamic = {};
	Reflect.setField(empty, "answer", 42);
	if (!Reflect.hasField(empty, "answer") || Std.int(Reflect.field(empty, "answer")) != 42)
		return 1;
	var seeded:Dynamic = {answer: 41};
	Reflect.setField(seeded, "extra", 1);
	var total = Std.int(Reflect.field(seeded, "answer")) + Std.int(Reflect.field(seeded, "extra"));
	return total == 42 ? 42 : 2;
}
