struct NumberCell {
 public var number:Null<Int>;
 public function new(number:Null<Int>) this.number = number;
}
function pass(value:Dynamic):Dynamic return value;
function main():Int {
 var values:Array<Null<NumberCell>> = [new NumberCell(1), null, new NumberCell(null), new NumberCell(8)];
 values.push(new NumberCell(11));
 var total = 0;
 for (entry in values) if (entry != null && entry.number != null) total += entry.number;
 var snapshot = values[4];
 values[4] = null;
 var restored:Null<NumberCell> = pass(snapshot);
 if (total != 20 || restored == null || restored.number != 11 || values[4] != null) return 1;
 if (values[0] == null || values[2] == null || values[2].number != null || values[1] != null) return 2;
	var removals:Array<Null<NumberCell>> = [new NumberCell(4), null, new NumberCell(7)];
	var last = removals.pop();
	var first = removals.shift();
	if (last == null || last.number != 7 || first == null || first.number != 4 || removals.length != 1 || removals[0] != null) return 3;
 return 42;
}
