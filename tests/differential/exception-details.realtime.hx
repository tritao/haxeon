// haxe.Exception's toString, details and stack, and CallStack.callStack, exceptionStack and toString, in Haxe's
// HashLink format: `Exception: <message>`, then `\nCalled from Class.method (file line N)` for each frame from the
// innermost out, and a chain of `previous` exceptions joined by `\n\nNext `. Frame positions and names may differ
// (Haxe's static methods are `$Class.method`, its files and lines are its own), so each frame is printed as its class
// and method, with its file and line normalized.
import haxe.CallStack;
import haxe.Exception;

class Failure extends Exception {
	public function new(message:String, ?previous:Exception) {
		super(message, previous);
		if (message.length == 0)
			throw "empty";
	}
}

class Main {
	static function normalize(text:String):String {
		var lines = [];
		for (line in text.split("\n")) {
			var open = line.indexOf(" (");
			if (StringTools.startsWith(line, "Called from ") && open > 0) {
				// The class and method, without a module path (Haxeon's class here lives in a module of another name).
				var name = line.substring("Called from ".length, open).split(".");
				line = "Called from " + name.slice(name.length - 2).join(".") + " (FILE line N)";
			}
			lines.push(StringTools.replace(line, "$", ""));
		}
		return lines.join("\n");
	}

	static function make(depth:Int):Exception {
		if (depth > 0)
			return make(depth - 1);
		return new Exception("made");
	}

	static function fail(message:String):Void {
		if (message.length > 0)
			throw new Failure(message);
	}

	static function chained():Exception {
		try {
			fail("first");
		} catch (e:Exception) {
			if (e.message.length > 0)
				return new Failure("second", e);
		}
		return null;
	}

	static function here(depth:Int):String {
		if (depth > 0)
			return here(depth - 1);
		return CallStack.toString(CallStack.callStack());
	}

	static function main() {
		var made = make(2);
		Sys.println("toString: " + made.toString());
		Sys.println("details: " + normalize(made.details()));
		Sys.println("stack frames: " + made.stack.length);
		Sys.println("callStack:" + normalize(here(1)));
		try {
			fail("thrown");
		} catch (e:Exception) {
			Sys.println("caught: " + normalize(e.details()));
			Sys.println("exceptionStack:" + normalize(CallStack.toString(CallStack.exceptionStack())));
		}
		try {
			throw "value";
		} catch (e:Exception) {
			Sys.println("value: " + e.toString() + " / " + normalize(e.details()));
		}
		Sys.println("chained: " + normalize(chained().details()));
	}
}
