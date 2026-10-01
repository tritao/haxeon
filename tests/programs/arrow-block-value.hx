// The value of an arrow function's block is its last expression, so `x -> { ...; value }` returns it, with the result
// type declared, expected by the caller, or inferred. A callback expected to return nothing discards it.
function twice(count:Int, step:Int->Int):Int
	return step(step(count));

function run(action:() -> Void):Void
	action();

function main():Int {
	var declared:(Int) -> Int = value -> {
		var doubled = value * 2;
		doubled + 1;
	};
	var inferred = (value:Int) -> {
		var tripled = value * 3;
		tripled;
	};
	var mapped = [1, 2, 3].map(value -> {
		var shifted = value + 10;
		shifted * 2;
	});
	var counter = 0;
	run(() -> {
		counter = counter + 1;
		counter * 100;
	});
	var passed = twice(5, value -> {
		var next = value + 1;
		next;
	});
	var noValue = 0;
	var assign = (value:Int) -> {
		noValue = value;
	};
	assign(7);
	var checks = [
		declared(4) == 9,
		inferred(5) == 15,
		mapped[0] == 22 && mapped[2] == 26,
		counter == 1,
		passed == 7,
		noValue == 7
	];
	for (check in checks)
		if (!check)
			return 1;
	return 42;
}
