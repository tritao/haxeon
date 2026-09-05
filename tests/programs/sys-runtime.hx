function main():Int {
	var cwd = Sys.getCwd();
	var now = Sys.time();
	if (cwd.length == 0 || !Sys.exists(cwd) || now < 0.0)
		return 0;
	return 42;
}
