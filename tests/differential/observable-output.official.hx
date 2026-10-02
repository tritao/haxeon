class Main {
	static function main():Void {
		// Haxe's trace format, with the path the realtime fixture is compiled from (official Haxe would name this
		// file under its temporary class path instead).
		Sys.println("tests/differential/observable-output.realtime.hx:2: value=42");
		Sys.exit(42);
	}
}
