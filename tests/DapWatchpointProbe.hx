function main():Int {
	Sys.sleep(1.0);
	var watched = 0;
	for (index in 1...4) {
		watched = index * 10;
		Sys.sleep(0.05);
	}
	return watched;
}
