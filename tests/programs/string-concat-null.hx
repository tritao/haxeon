class Holder {
	public var name:Null<String> = null;

	public function new() {}
}

class Main {
	static function nothing():Null<String>
		return null;

	static function main():Int {
		var missing:Null<String> = null;
		var holder = new Holder();
		// A String typed as non-null can still hold null at run time, as values from Sys.getEnv or Dynamic do.
		var unknown:Dynamic = null;
		var leaked:String = unknown;
		var failures = 0;
		if (missing + "/project" != "null/project")
			failures |= 1;
		if ("root/" + missing != "root/null")
			failures |= 2;
		if (holder.name + "!" != "null!")
			failures |= 4;
		if (nothing() + "" != "null")
			failures |= 8;
		var built = "a";
		built += missing;
		if (built != "anull")
			failures |= 16;
		if (missing + missing != "nullnull" || missing + 1 != "null1")
			failures |= 32;
		if (leaked + "/project" != "null/project" || "root/" + leaked != "root/null")
			failures |= 64;
		var chained = "a" + leaked + "b" + leaked + "c";
		if (chained != "anullbnullc")
			failures |= 128;
		var appended = "a";
		appended += leaked;
		if (appended != "anull")
			failures |= 256;
		var parts:Array<String> = [leaked, "a", null];
		if (parts.join(",") != "null,a,null")
			failures |= 512;
		var present:Null<String> = "set";
		if (present + "/project" != "set/project" || 'x$missing' != "xnull")
			failures |= 1024;
		// Exits with the failed checks' bits, so a failure says which checks broke.
		return failures == 0 ? 42 : failures;
	}
}
