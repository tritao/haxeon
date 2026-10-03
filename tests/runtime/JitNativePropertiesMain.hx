@:hlNative("jit_native_properties")
extern class NativeProperties {
	static function flagged_throw():Void;
	static function unflagged_throw():Void;
	static function ordinary_call(value:Float):Float;
}

/** External native declarations control non-returning calls; missing markers remain ordinary calls. */
class JitNativePropertiesMain {
	static function main():Void {
		var caught = 0;
		var live = 3.25;
		try {
			NativeProperties.flagged_throw();
		} catch (_:Dynamic) {
			caught++;
			if (live != 3.25)
				Sys.exit(1);
		}
		try {
			NativeProperties.unflagged_throw();
		} catch (_:Dynamic) {
			caught++;
			if (live != 3.25)
				Sys.exit(2);
		}
		var total = 0.0;
		for (i in 0...1000) {
			var before = i + 0.25;
			var result = NativeProperties.ordinary_call(before);
			total += before + result;
		}
		if (caught != 2 || total != 1000000.0)
			Sys.exit(3);
		Sys.println("PASS: external native noreturn declarations and ordinary loop calls");
	}
}
