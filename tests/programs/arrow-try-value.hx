function main():Int {
	var action:() -> Int = () -> {
		try {
			var value = 42;
			value;
		} catch (e:Dynamic) {
			throw e;
		}
	};
	if (action() != 42)
		return 1;
	var recover:() -> Int = () -> {
		try {
			if (true)
				throw "recover";
			0;
		} catch (e:Dynamic) {
			21;
		}
	};
	if (recover() != 21)
		return 2;
	var rethrow:() -> Int = () -> {
		try {
			if (true)
				throw "expected";
			42;
		} catch (e:Dynamic) {
			throw e;
		}
	};
	var caught = false;
	try
		rethrow()
	catch (e:Dynamic)
		caught = e == "expected";
	return caught ? 42 : 3;
}
