function main():Int {
	var flags = new Map<String, Bool>();
	flags["enabled"] = true;
	var ratios = new Map<String, Float>();
	ratios["answer"] = 42.5;
	var ratio = ratios.get("answer");
	var labels = new Map<String, String>();
	labels["answer"] = "forty-two";
	if (flags.exists("enabled") == false)
		return 0;
	if (flags.get("enabled") == false)
		return 0;
	if (labels.get("answer") == "forty-two")
		return 42;
	return 0;
}
