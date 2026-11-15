// FileSystem.stat, Date.fromTime and Timer.stamp give Haxe's results.
function main():Int {
	var path = "out/stdlib-stat-fphelper.txt";
	sys.io.File.saveContent(path, "12345");
	var stat = sys.FileSystem.stat(path);
	if (stat.size != 5 || stat.mtime.getTime() <= 0 || stat.mtime.getTime() > Date.now().getTime() + 1000)
		return 1;
	try {
		sys.FileSystem.stat("out/no-such-file");
		return 2;
	} catch (_:Dynamic) {}
	if (Date.fromTime(1500.0).getTime() != 1500.0)
		return 3;
	var start = haxe.Timer.stamp();
	return haxe.Timer.stamp() >= start ? 42 : 6;
}
