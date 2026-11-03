struct ArrayEqualityItem implements Equatable {
	public var value:Int;
	public function new(value:Int) this.value = value;
	public function equals(other:ArrayEqualityItem):Bool return value % 10 == other.value % 10;
}

function main():Int {
	var values = [new ArrayEqualityItem(1), new ArrayEqualityItem(2), new ArrayEqualityItem(12), new ArrayEqualityItem(3)];
	if (values.indexOf(new ArrayEqualityItem(22)) != 1 || !values.contains(new ArrayEqualityItem(13))) return 1;
	if (!values.remove(new ArrayEqualityItem(22)) || values.length != 3 || values[1].value != 12) return 2;
	if (values.remove(new ArrayEqualityItem(9)) || values.indexOf(new ArrayEqualityItem(9)) != -1) return 3;
	var optional:Array<Null<ArrayEqualityItem>> = [null, new ArrayEqualityItem(7), null];
	if (optional.indexOf(null) != 0 || optional.indexOf(new ArrayEqualityItem(17)) != 1) return 4;
	if (!optional.remove(null) || optional.length != 2 || optional[0] == null || optional[0].value != 7) return 5;
	return 42;
}
