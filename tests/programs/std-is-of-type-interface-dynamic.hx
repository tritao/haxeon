// A class instance held as Dynamic is of the interfaces its class implements, those it inherits, and those that extend them.
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

function main():Int {
	var timeout:Dynamic = new Timeout();
	var refused:Dynamic = new Refused();
	var crash:Dynamic = new Crash();
	var unrelated:Dynamic = new Unrelated();
	var checks = [
		Std.isOfType(timeout, Failure),
		!Std.isOfType(timeout, Fatal),
		Std.isOfType(refused, Failure),
		Std.isOfType(crash, Fatal),
		Std.isOfType(crash, Failure),
		!Std.isOfType(unrelated, Failure),
		Std.isOfType(timeout, Timeout)
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
