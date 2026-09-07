function main():Int {
	Sys.sleep(1.0);
	var total = 0;
	for (index in 0...3) {
		var doubled = index * 2;
		total = total + doubled;
		Sys.sleep(0.05);
	}
	return total;
}
