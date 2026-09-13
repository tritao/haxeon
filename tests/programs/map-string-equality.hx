function main():Int {
	var key = "ans";
	key += "wer";
	var values = new Map<String, Int>();
	values["answer"] = 1;
	values[key] = 42;
	if (values.size() != 1)
		return 0;
	return values.get("answer");
}
