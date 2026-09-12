class ProfilerDisconnectTarget {
	static function main():Void {
		Sys.println("started");
		var until = Sys.time() + 0.4;
		while (Sys.time() < until)
			Sys.sleep(0.01);
	}
}
