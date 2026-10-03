enum Choice {
	Empty;
	Other;
	Value(value:Int);
}

function main():Int {
	var shared:Choice = Empty;
	var choices:Array<Choice> = [Empty, shared, Other];
	if (choices.indexOf(shared) != 0 || !choices.contains(Empty) || choices.indexOf(Other) != 2)
		return 1;
	var payload:Choice = Value(7);
	var payloads:Array<Choice> = [Empty, payload];
	if (payloads.indexOf(payload) != 1 || payloads.indexOf(Value(7)) != -1)
		return 2;
	var nullable:Array<Null<Choice>> = [null, Other, Empty];
	if (nullable.indexOf(null) != 0 || nullable.indexOf(Empty) != 2 || !nullable.contains(Other))
		return 3;
	var empty:Array<Choice> = [];
	if (empty.indexOf(Empty) != -1)
		return 4;
	return 42;
}
