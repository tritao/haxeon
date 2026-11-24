class Probe {
	static function main() {
		var args = Sys.args();
		var count = args.length == 0 ? 0 : Std.parseInt(args[0]) ?? 0;
		count += 1;
		count *= 2;
		Sys.println(count);
	}
}
