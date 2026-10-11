class RuntimeNeutralMarker {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

class RuntimeNeutralProbe {
	static var cleanupCount = 0;

	static function throwFromCallee():Void {
		throw new RuntimeNeutralMarker(42);
	}

	static function throwThroughClosure():Void {
		var callback:Void->Void = throwFromCallee;
		callback();
	}

	static function cleanupOnBothPaths(shouldThrow:Bool):Int {
		var value = 0;
		try {
			if (shouldThrow)
				throwThroughClosure();
			value = 40;
		} catch (error:Dynamic) {
			cleanupCount++;
			var keepPendingRooted:Array<Dynamic> = [error];
			if (keepPendingRooted.length == 0)
				return 0;
			throw error;
		}
		cleanupCount++;
		return value + 2;
	}

	static function loopChecksum(count:Int):Int {
		var value = 0;
		var index = 0;
		while (index < count) {
			value += index;
			index++;
		}
		return value;
	}

	public static function fuelLoop(count:Int):Int {
		var index = 0;
		while (index < count)
			index++;
		return index;
	}

	public static function fuelTrapCatch(count:Int):Int {
		try {
			fuelLoop(count);
		} catch (error:Dynamic) {
			return 0;
		}
		return 42;
	}

	public static function main():Int {
		var normal = cleanupOnBothPaths(false);
		var caught = false;
		try {
			cleanupOnBothPaths(true);
		} catch (error:Dynamic) {
			var marker:RuntimeNeutralMarker = cast error;
			caught = marker.value == 42;
		}
		if (normal != 42 || !caught || cleanupCount != 2)
			return 1;
		if (loopChecksum(1000) != 499500)
			return 2;
		return 42;
	}
}

function main():Int
	return RuntimeNeutralProbe.main();
