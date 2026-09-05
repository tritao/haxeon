function main():Int {
	var values = new Map<String, Int>();
	values["answer"] = 42;
	values.set("other", 7);
	if (values.exists("answer"))
		return values.get("answer");
	return 0;
}
