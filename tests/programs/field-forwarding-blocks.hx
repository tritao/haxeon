class ForwardBox {
	public var value:Int;
	public var other:Int;
	public function new(value:Int) { this.value = value; other = 0; }
}

function acrossJoin(object:ForwardBox, branch:Bool):Int {
	var first = object.value;
	if (branch) object.other = 1; else object.other = 2;
	return first + object.value;
}

function acrossAlias(object:ForwardBox, alias:ForwardBox, branch:Bool):Int {
	var first = object.value;
	if (branch) alias.value = 7;
	return first + object.value;
}

function change(object:ForwardBox):Void object.value = 9;
function acrossCall(object:ForwardBox):Int {
	var first = object.value;
	change(object);
	return first + object.value;
}

function acrossLoop(object:ForwardBox, changeValue:Bool):Int {
	var first = object.value;
	var i = 0;
	while (i < 2) {
		if (changeValue) object.value = object.value + 1;
		i++;
	}
	return first + object.value;
}

function main():Int {
	var object = new ForwardBox(3);
	if (acrossJoin(object, true) != 6) return 1;
	if (acrossAlias(object, object, true) != 10) return 2;
	if (acrossCall(object) != 16) return 3;
	if (acrossLoop(object, true) != 20) return 4;
	if (acrossLoop(object, false) != 22) return 5;
	return 42;
}
