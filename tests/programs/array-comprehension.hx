function main():Int {
	var values:Map<String, Int> = new Map<String, Int>();
	values["answer"] = 42;
	var copied = [for (_ => value in values) value];
	var doubled = [for (value in copied) value * 2];
	return Std.int(doubled[0] / 2);
}
