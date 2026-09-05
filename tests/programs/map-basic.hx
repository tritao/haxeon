function main():Int {
	var values = new Map<String, Int>();
	values["answer"] = 42;
	values.set("other", 7);
	if (values.size() != 2)
		return 0;
	if (!values.remove("other") || values.exists("other"))
		return 0;
	if (values.size() != 1)
		return 0;
	values.set("other", 7);
	if (values.exists("answer"))
		for (key in values.keys())
			if (key == "answer")
				return values.get(key);
	return 0;
}
