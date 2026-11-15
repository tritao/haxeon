function main():Int { // @formatter:off: the DAP tests address this file by line
	Sys.sleep(1.0);
	var total = 0;
	for (index in 0...5) {
		var candidate = index * 3;
		total = total + candidate;
		Sys.sleep(0.05);
	}
	return total;
}
