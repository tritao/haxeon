// A switch over a nullable Int, String or enum abstract matches `case null` apart from the values. Without a default, a
// switch over a nullable enum abstract covers its values and need not match null, as one over a Null<Enum>: a null its
// arms leave throws "Null access", and an undeclared value "Unmatched". A catch-all or a capture still sees the nullable.
enum abstract Kind(Int) from Int {
	var A = 1;
	var B = 2;
}

enum abstract Tag(String) {
	var X = "x";
	var Y = "y";
}

function kind(k:Null<Kind>):Int
	return switch k {
		case null: 0;
		case A: 1;
		case B: 2;
	};

function tag(t:Null<Tag>):Int {
	switch t {
		case null:
			return 0;
		case X:
			return 1;
		case Y:
			return 2;
	}
}

function bare(k:Null<Kind>):Int
	return switch k {
		case A: 1;
		case B: 2;
	};

function bareStatement(t:Null<Tag>):Int {
	switch t {
		case X:
			return 1;
		case Y:
			return 2;
	}
}

function guardedNull(k:Null<Kind>, allow:Bool):Int
	return switch k {
		case null if (allow): 0;
		case A: 1;
		case B: 2;
	};

function thrown(run:() -> Int):String {
	try
		run()
	catch (error:Dynamic)
		return Std.string(error);
	return "none";
}

function count(n:Null<Int>):Int
	return switch n {
		case 1 | 2: 10;
		case null: -1;
		case other: other == 7 ? 7 : 0;
	};

function captured(k:Null<Kind>):Int
	return switch k {
		case some = A | B: some == A ? 100 : 200;
		case absent: absent == null ? 0 : 9;
	};

function guarded(t:Null<Tag>, allow:Bool):Int
	return switch t {
		case X if (allow): 1;
		case null if (allow): 2;
		default: 3;
	};

function main():Int {
	if (kind(null) != 0 || kind(A) != 1 || kind(B) != 2)
		return 1;
	if (tag(null) != 0 || tag(X) != 1 || tag(Y) != 2)
		return 2;
	if (count(2) != 10 || count(null) != -1 || count(7) != 7)
		return 3;
	if (captured(A) != 100 || captured(B) != 200 || captured(null) != 0 || captured(5) != 9)
		return 4;
	if (guarded(X, true) != 1
		|| guarded(null, true) != 2
		|| guarded(X, false) != 3
		|| guarded(null, false) != 3
		|| guarded(Y, true) != 3)
		return 5;
	if (bare(A) != 1 || bare(B) != 2 || bareStatement(X) != 1 || bareStatement(Y) != 2 || guardedNull(null, true) != 0
		|| guardedNull(B, false) != 2)
		return 7;
	if (thrown(() -> bare(null)) != "Null access" || thrown(() -> bareStatement(null)) != "Null access"
		|| thrown(() -> guardedNull(null, false)) != "Null access")
		return 8;
	if (thrown(() -> bare(9)) != "Unmatched Null<Kind> value")
		return 9;
	var unmatched = false;
	try
		kind(9)
	catch (error:Dynamic)
		unmatched = Std.string(error).indexOf("Unmatched") >= 0;
	if (!unmatched)
		return 6;
	return 42;
}
