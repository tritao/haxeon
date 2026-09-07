function worker(value:Int):Int {
	return value + 1;
}

function main():Int {
	Sys.sleep(1.0);
	return worker(41);
}
