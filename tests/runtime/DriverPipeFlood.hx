import haxe.io.Bytes;

/** Exercise the driver's concurrent stream drains, with a deadline if either pipe stalls. */
class DriverPipeFlood {
	static function main():Void {
		sys.thread.Thread.create(() -> {
			Sys.sleep(30);
			Sys.exit(124);
		});
		var bytes = Bytes.alloc(220000);
		bytes.fill(0, bytes.length, 120);
		var output = Sys.args()[0] == "stdout" ? Sys.stdout() : Sys.stderr();
		output.write(bytes);
		output.flush();
		Sys.exit(0);
	}
}
