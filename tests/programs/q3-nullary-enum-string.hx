enum NullaryStringCase {
	First;
	Second;
}

function main():Int {
	var value:Dynamic = NullaryStringCase.Second;
	return Std.string(value) == "Second" ? 42 : 1;
}
