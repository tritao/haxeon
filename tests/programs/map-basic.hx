function main():Int {
	var values = new Map<String, Int>();
	values["answer"] = 42;
	values.set("other", 7);
	if (values.exists("answer"))
		for (key in values.keys())
			if (key == "answer")
				return values.get(key);
	return 0;
}
