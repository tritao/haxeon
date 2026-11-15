// A catch clause binds an enum type as Haxe's does: it catches the values of that enum, payloads included, and lets anything
// else reach the next clause.
enum Failure {
	Blocked;
	Overflow;
	Custom(message:String);
}

enum Other {
	Elsewhere;
}

class Problem {
	public final code:Int;

	public function new(code:Int)
		this.code = code;
}

function fail(kind:Int):Void {
	if (kind < 0)
		return;
	switch kind {
		case 0:
			throw Failure.Overflow;
		case 1:
			throw Custom("disk");
		case 2:
			throw Other.Elsewhere;
		case 3:
			throw new Problem(7);
		default:
			throw "text";
	}
}

function classify(kind:Int):String {
	try {
		fail(kind);
		return "none";
	} catch (failure:Failure) {
		return switch failure {
			case Blocked: "blocked";
			case Overflow: "overflow";
			case Custom(message): 'custom $message';
		};
	} catch (other:Other) {
		return other == Elsewhere ? "elsewhere" : "other";
	} catch (problem:Problem) {
		return 'problem ${problem.code}';
	} catch (text:String) {
		return 'string $text';
	}
}

function main():Int {
	var results = [for (kind in -1...5) classify(kind)].join(",");
	if (results != "none,overflow,custom disk,elsewhere,problem 7,string text")
		return 1;
	try {
		try
			fail(0)
		catch (other:Other)
			return 2;
		return 3;
	} catch (failure:Failure) {
		if (failure != Overflow)
			return 4;
	}
	return 42;
}
