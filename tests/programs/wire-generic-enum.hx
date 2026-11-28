#if !wasm
import haxeon.wire.JsonWire;
#end
import haxeon.wire.MessagePack;

// A generic enum is a wire type for wire-typed arguments: Result<T, E> round-trips through MessagePack and JSON for
// each instantiation, a Void payload (Ok() of Result<Void, E>) is not written, and generic enums nest in records,
// arrays and one another. (JSON is checked natively: the Wasm targets do not provide its float parsing yet.)

private enum Refusal {
	NotAllowed(reason:String);
	Busy;
}

private enum Pair<A, B> {
	Both(first:A, second:B);
	Neither;
}

private class Answer {
	public final value:Result<Int, String>;
	public final saved:Result<Void, Refusal>;
	public final history:Array<Result<String, Refusal>>;
	public final pairs:Pair<Pair<Int, String>, Null<Bool>>;

	public function new(value, saved, history, pairs) {
		this.value = value;
		this.saved = saved;
		this.history = history;
		this.pairs = pairs;
	}
}

function describe(answer:Answer):String {
	var value = switch answer.value {
		case Ok(number): 'ok $number';
		case Err(text): 'err $text';
	};
	var saved = switch answer.saved {
		case Ok(_): "saved";
		case Err(NotAllowed(reason)): 'refused $reason';
		case Err(Busy): "busy";
	};
	var history = [for (entry in answer.history) switch entry {
		case Ok(text): text;
		case Err(Busy): "busy";
		case Err(NotAllowed(reason)): reason;
	}].join(",");
	var pairs = switch answer.pairs {
		case Both(Both(number, text), flag): '$number/$text/$flag';
		case Both(Neither, flag): 'neither/$flag';
		case Neither: "none";
	};
	return '$value $saved [$history] $pairs';
}

function main():Int {
	var answer = new Answer(Ok(7), Ok(), [Ok("one"), Err(Busy), Err(NotAllowed("two"))], Both(Both(3, "x"), null));
	var expected = "ok 7 saved [one,busy,two] 3/x/null";
	if (describe(MessagePack.decode<Answer>(MessagePack.encode(answer)).unwrap()) != expected)
		return 1;
	var refused = new Answer(Err("no"), Err(NotAllowed("full")), [], Neither);
	var refusedExpected = "err no refused full [] none";
	if (describe(MessagePack.decode<Answer>(MessagePack.encode(refused)).unwrap()) != refusedExpected)
		return 2;
	// A root generic enum, and Void's payload left out: Ok() is the case with an empty payload.
	var root:Result<Void, Refusal> = Ok();
	if (!MessagePack.decode<Result<Void, Refusal>>(MessagePack.encode(root)).unwrap().isOk())
		return 3;
	#if !wasm
	if (describe(JsonWire.decode<Answer>(JsonWire.encode(answer)).unwrap()) != expected
		|| describe(JsonWire.decode<Answer>(JsonWire.encode(refused)).unwrap()) != refusedExpected)
		return 4;
	if (JsonWire.encode(root) != '{"version":1,"value":{"Ok":[]}}')
		return 5;
	#end
	return 42;
}
