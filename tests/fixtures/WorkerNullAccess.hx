import sys.thread.Thread;
import sys.thread.Lock;
import haxe.CallStack;

class Target {
	public var value:Int = 42;

	public function new() {}

	public function run():Int
		return value;
}

enum Payload {
	Value(value:Int);
}

function resolveTarget(target:Target):Int
	return target.value;

function writeTarget(target:Target):Int {
	target.value = 1;
	return 0;
}

function callTarget(target:Target):Int
	return target.run();

function bindTarget(target:Target):Int {
	var call = target.run;
	return call();
}

function arrayLength(values:Array<Int>):Int
	return values.length;

function arrayRead(values:Array<Int>):Int
	return values[0];

function arrayWrite(values:Array<Int>):Int {
	values[0] = 1;
	return 0;
}

function enumRead(value:Payload):Int
	return switch value {
		case Value(n): n;
	};

function check():Bool {
	var checks:Array<Void->Int> = [
		function() return resolveTarget(null), function() return writeTarget(null),
		   function() return callTarget(null),  function() return bindTarget(null),
		  function() return arrayLength(null),   function() return arrayRead(null),
		   function() return arrayWrite(null),    function() return enumRead(null)
	];
	for (index in 0...checks.length) {
		var caught = false;
		try {
			checks[index]();
		} catch (error:Dynamic) {
			var stack = CallStack.toString(CallStack.exceptionStack());
			caught = Std.string(error).indexOf("Null access") >= 0 && stack.indexOf("WorkerNullAccess.hx:") >= 0;
			if (index == 0)
				caught = caught && stack.indexOf("resolveTarget") >= 0;
			if (!caught)
				Sys.println(Std.string(error) + "\n" + stack);
		}
		if (!caught) {
			Sys.println("Null check failed at operation " + index);
			return false;
		}
	}
	// A completed catch must leave the thread's surrounding handler usable.
	try {
		try {
			throw "nested";
		} catch (error:Dynamic) {
			throw error;
		}
	} catch (error:Dynamic) {
		return Std.string(error) == "nested";
	}
}

function main():Int {
	if (!check())
		return 1;
	var completions:Array<Lock> = [];
	var results:Array<Bool> = [];
	for (index in 0...4) {
		var done = new Lock();
		completions.push(done);
		results.push(false);
		var slot = index;
		Thread.create(function() {
			var passed = true;
			for (repeat in 0...8)
				if (!check())
					passed = false;
			results[slot] = passed;
			done.release();
		});
	}
	for (done in completions)
		if (!done.wait(10.0))
			return 2;
	for (passed in results)
		if (!passed)
			return 3;
	return 42;
}
