@:hlNative("gcclaim") private extern class GcClaimHooks {
	static function run():Int;
}

class GcMarkClaimProbe {
	static function main():Void {
		var failures = GcClaimHooks.run();
		if (failures != 0)
			Sys.exit(1);
		Sys.println("PASS: bitmap claims");
	}
}
