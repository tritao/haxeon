class Main {
	static function nested():Void {
		var value = 1;
		var read = () -> value;
		var bump = () -> {
			value++;
			return value;
		};
		try {
			try {
				Sys.println("inner:" + bump());
				throw "inner";
			} catch (error:String) {
				Sys.println("caught:" + error + ":" + read());
				bump();
				throw "outer";
			}
		} catch (error:Dynamic) {
			Sys.println("outer:" + read());
			if (true) {
				var value = 90;
				var local = () -> {
					value++;
					return value;
				};
				Sys.println("shadow:" + local());
			}
		}
		Sys.println("after:" + read() + ":" + bump());
	}

	static function closureThrow():Void {
		var value = 10;
		var fail = () -> {
			value += 2;
			throw "closure";
		};
		try {
			fail();
		} catch (error:String) {
			Sys.println("closure:" + value);
		}
		var read = () -> value;
		value++;
		Sys.println("shared:" + read());
	}

	static function iterations():Void {
		var callbacks:Array<() -> Int> = [];
		for (i in 0...3) {
			var local = i * 10;
			callbacks.push(() -> {
				local++;
				return local;
			});
		}
		for (callback in callbacks)
			Sys.println("iteration:" + callback());
		for (callback in callbacks)
			Sys.println("again:" + callback());
	}

	static function main():Void {
		nested();
		closureThrow();
		iterations();
	}
}
