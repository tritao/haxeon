enum Value<T:Equatable> : Equatable { Item(value:T); }

function main():Int {
	var typed:Array<Value<Int>> = [Value.Item(1)], view:Array<Dynamic> = cast typed;
	var eight:Value<Int> = Value.Item(8), nine:Value<Int> = Value.Item(9), four:Value<Int> = Value.Item(4);
	view[0] = eight;
	view.push(nine);
	view.insert(1, four);
	if (typed.length != 3) return 1;
	switch typed[0] { case Item(value) if (value == 8): default: return 2; }
	switch typed[1] { case Item(value) if (value == 4): default: return 3; }
	switch typed[2] { case Item(value) if (value == 9): default: return 4; }
	var rejected = false;
	var wrong:Value<String> = Value.Item("wrong");
	try view[5] = wrong catch (_:Dynamic) rejected = true;
	if (!rejected || typed.length != 3) return 5;
	return 42;
}
