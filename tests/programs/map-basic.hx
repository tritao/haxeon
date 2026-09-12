function main():Int {
	var values = new Map<String, Int>();
	values["answer"] = 42;
	values.set("other", 7);
	if (values.size() != 2)
		return 0;
	var foundAnswer = false, foundOther = false, valueCount = 0;
	for (value in values.values()) {
		valueCount++;
		foundAnswer = foundAnswer || value == 42;
		foundOther = foundOther || value == 7;
	}
	if (valueCount != 2 || !foundAnswer || !foundOther)
		return 0;
	if (!values.remove("other") || values.exists("other"))
		return 0;
	if (values.size() != 1)
		return 0;
	values.set("other", 7);
	foundAnswer = false;
	for (value in values.values())
		foundAnswer = foundAnswer || value == 42;
	if (!foundAnswer)
		return 0;
	if (values.exists("answer"))
		for (key in values.keys())
			if (key == "answer")
				return values.get(key);
	return 0;
}
