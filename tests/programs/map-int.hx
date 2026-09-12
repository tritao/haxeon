function main():Int {
	var values = new Map<Int, Int>();
	values[7] = 42;
	values.set(9, 1);
	if (!values.exists(7))
		return 0;
	var found = false;
	for (value in values.values())
		found = found || value == 42;
	if (!found)
		return 0;
	var sum = 0;
	for (key in values.keys())
		sum = sum + values.get(key);
	if (!values.remove(9) || values.exists(9))
		return 0;
	values.set(9, 1);
	var flags = new Map<Int, Bool>();
	flags[7] = true;
	flags.clear();
	if (flags.exists(7))
		return 0;
	flags[7] = true;
	var ratios = new Map<Int, Float>();
	ratios[7] = 0.5;
	var labels = new Map<Int, String>();
	labels[7] = "ok";
	if (!flags.get(7) || ratios.get(7) < 0.5 || labels.get(7) != "ok")
		return 0;
	return sum - 1;
}
