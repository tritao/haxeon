class ProfilerWaitTarget {
	static function main():Void {
		Sys.println("started");
		var until = Sys.time() + 2.0;
		while (Sys.time() < until)
			Sys.sleep(0.01);
	}
}
