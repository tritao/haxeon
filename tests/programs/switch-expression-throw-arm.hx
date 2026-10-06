enum Poll {
	Waiting;
	Done(value:Int);
	Broken(code:Int);
	Lost(code:Int);
}

enum Outcome {
	Idle;
	Resolved(value:Int);
}

// Arms whose statements end in a throw take the switch's result type.
function settle(poll:Poll):Outcome {
	return switch poll {
		case Waiting: Idle;
		case Broken(code):
			var message = "broken " + code;
			throw message;
		case Lost(code): {
				var message = "lost " + code;
				throw message;
			}
		case Done(value):
			Resolved(value);
	};
}

function checked(value:Int):Int {
	var result = if (value >= 0) value else {
		var message = "negative";
		throw message;
	};
	return result;
}

function main():Int {
	var total = 0;
	switch settle(Done(38)) {
		case Resolved(value):
			total += value;
		case Idle:
	}
	if (settle(Waiting) == Idle)
		total += 1;
	try {
		settle(Broken(7));
	} catch (error:String) {
		if (error == "broken 7")
			total += 1;
	}
	try {
		settle(Lost(3));
	} catch (error:String) {
		if (error == "lost 3")
			total += 1;
	}
	try {
		checked(-1);
	} catch (error:String) {
		if (error == "negative")
			total += checked(1);
	}
	return total;
}
