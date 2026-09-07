class ProfilerRestartTarget {
	static function main():Void {
		var until = Sys.time() + 2.0, value = 1;
		while (Sys.time() < until) value = (value * 33) ^ 17;
		if (value == 0) Sys.println(value);
	}
}
