// `Void` is the unit type: a `Result<Void, E>` succeeds with no value (`Ok()`, `case Ok():`), a `Void` parameter takes no
// argument (`unwrapOr()`), and a `T->U` at `T` = `Void` is a function with no arguments (`map(() -> 7)`).
enum SaveError {
	Full;
	Lost;
}

var saves = 0;

function save(fits:Bool):Result<Void, SaveError> {
	saves++;
	return fits ? Ok() : Err(Full);
}

function saveBoth(first:Bool, second:Bool):Result<Void, SaveError> {
	try save(first);
	try save(second);
	return Ok();
}

function describe(result:Result<Void, SaveError>):String
	return switch result {
		case Ok(): "saved";
		case Err(Full): "full";
		case Err(Lost): "lost";
	}

var bumps = 0;

function bump():Void
	bumps++;

// A case whose payload is `Void` at one position still stores the payloads after it.
enum Pair<A, B> {
	Both(first:A, second:B);
}

function second(pair:Pair<Void, Int>):Int
	return switch pair {
		case Both(_, value): value;
	}

// A pattern leaves out a `Void` payload as the constructor call does.
function secondLeftOut(pair:Pair<Void, Int>):Int
	return switch pair {
		case Both(value): value;
	}

function main():Int {
	if (!save(true).isOk() || !save(false).isErr() || describe(save(true)) != "saved"
		|| describe(save(false)) != "full")
		return 1;
	switch save(true).map(() -> 7) {
		case Ok(7):
		default:
			return 2;
	}
	switch save(false).mapErr(error -> Lost) {
		case Err(Lost):
		default:
			return 3;
	}
	if (describe(save(true).mapErr(error -> Lost)) != "saved")
		return 4;
	switch save(true).andThen(() -> Ok(5)) {
		case Ok(5):
		default:
			return 5;
	}
	if (describe(saveBoth(true, false)) != "full" || describe(saveBoth(true, true)) != "saved")
		return 6;
	save(true).unwrap();
	save(true).unwrapOr();
	if (describe(save(true).map(() -> bump())) != "saved" || bumps != 1)
		return 7;
	if (second(Both(42)) != 42 || secondLeftOut(Both(42)) != 42)
		return 8;
	var before = saves;
	_ = save(true);
	return saves == before + 1 ? 42 : 9;
}
