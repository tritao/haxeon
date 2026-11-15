function worker(value:Int):Int { // @formatter:off: the DAP tests address this file by line
	return value + 1;
}

function main():Int {
	Sys.sleep(1.0);
	return worker(41);
}
