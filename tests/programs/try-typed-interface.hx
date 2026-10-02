// A catch clause can name an interface: it takes any thrown object whose class implements it (or an interface extending
// it, or a subclass of an implementer), and nothing else.
interface Failure {
	function code():Int;
}

interface Fatal extends Failure {
	function reason():String;
}

class Timeout implements Failure {
	public function new() {}

	public function code():Int
		return 40;
}

class Refused extends Timeout {
	public function new() {
		super();
	}

	override public function code():Int
		return 2;
}

class Crash implements Fatal {
	public function new() {}

	public function code():Int
		return 7;

	public function reason():String
		return "crash";
}

class Unrelated {
	public function new() {}
}

function attempt(kind:Int):Int {
	try {
		if (kind == 0)
			throw new Timeout();
		if (kind == 1)
			throw new Refused();
		if (kind == 2)
			throw new Crash();
		throw new Unrelated();
	} catch (failure:Failure) {
		return failure.code();
	} catch (other:Unrelated) {
		return 100;
	}
}

function main():Int {
	var timeout = attempt(0),
		refused = attempt(1),
		crash = attempt(2),
		unrelated = attempt(3);
	// An interface catch is skipped for an object that does not implement it, and the exception goes on to the next clause.
	var skipped = 0;
	try {
		try {
			throw new Unrelated();
		} catch (failure:Failure) {
			skipped = -1;
		}
	} catch (outer:Unrelated) {
		skipped = 5;
	}
	// An interface-typed value that is thrown still matches a class or interface clause.
	var viaInterface = 0;
	try {
		var thrown:Failure = new Crash();
		throw thrown;
	} catch (fatal:Fatal) {
		viaInterface = fatal.code() + 1;
	}
	// The binding is usable as the interface that was caught.
	var reason = "";
	try {
		throw new Crash();
	} catch (fatal:Fatal) {
		reason = fatal.reason();
	}
	var checks = [
		timeout == 40,
		refused == 2,
		crash == 7,
		unrelated == 100,
		skipped == 5,
		viaInterface == 8,
		reason == "crash"
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
