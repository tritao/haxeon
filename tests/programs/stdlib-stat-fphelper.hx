import haxe.io.FPHelper;

// FileSystem.stat, Date.fromTime, FPHelper and Timer.stamp give Haxe's results.
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
	if (FPHelper.floatToI32(1.0) != 0x3F800000 || FPHelper.i32ToFloat(0x40000000) != 2.0)
		return 4;
	var bits = FPHelper.doubleToI64(1.0);
	if (haxe.Int64.toStr(bits) != "4607182418800017408" || FPHelper.i64ToDouble(0, 0x3FF00000) != 1.0)
		return 5;
	var start = haxe.Timer.stamp();
	return haxe.Timer.stamp() >= start ? 42 : 6;
}
