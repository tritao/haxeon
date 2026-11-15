function main():Int { // @formatter:off: the DAP tests address this file by line
	Sys.sleep(1.0);
	var watched = 0;
	for (index in 1...4) {
		watched = index * 10;
		Sys.sleep(0.05);
	}
	return watched;
}
