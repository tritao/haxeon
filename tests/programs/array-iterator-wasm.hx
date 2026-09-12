class IteratorItem {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var values = [20, 22],
		first = values.iterator(),
		second = values.iterator();
	if (!first.hasNext() || first.next() != 20 || !second.hasNext() || second.next() != 20)
		return 0;
	values.push(5);
	if (first.next() != 22
		|| second.next() != 22
		|| first.next() != 5
		|| second.next() != 5
		|| first.hasNext()
		|| second.hasNext())
		return 0;

	var booleans = [false, true], booleanIterator = booleans.iterator();
	if (!booleanIterator.hasNext() || booleanIterator.next() || booleanIterator.next() != true || booleanIterator.hasNext())
		return 0;

	var fractions = [0.5, 1.5], fractionIterator = fractions.iterator();
	if (fractionIterator.next() != 0.5 || fractionIterator.next() != 1.5 || fractionIterator.hasNext())
		return 0;

	var labels = ["left", "right"], labelIterator = labels.iterator();
	if (labelIterator.next() != "left" || labelIterator.next() != "right" || labelIterator.hasNext())
		return 0;

	var items = [new IteratorItem(10), new IteratorItem(32)],
		itemIterator = items.iterator();
	if (itemIterator.next().value != 10 || itemIterator.next().value != 32 || itemIterator.hasNext())
		return 0;

	var empty:Array<Int> = [];
	return empty.iterator().hasNext() ? 0 : 42;
}
