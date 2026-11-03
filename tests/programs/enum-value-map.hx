import haxeon.Hashing;

enum ValueKey : Hashable {
	Number(value:Int);
	Pair(first:Int, second:Int);
	Empty;
}

enum GenericTag<T> { First; Second; }

function main():Int {
	var values:Map<ValueKey, Int> = new Map();
	values.set(Number(1), 10);
	values.set(Number(2), 20);
	values.set(Pair(1, 2), 30);
	values.set(Empty, 40);
	if (values.size() != 4 || values.get(Number(1)) != 10 || values.get(Number(2)) != 20) return 1;
	if (values.get(Pair(1, 2)) != 30 || values.get(Empty) != 40) return 2;
	if (Hashing.hash(Number(1)) != Hashing.hash(Number(1))) return 3;
	if (!values.remove(Number(1)) || values.exists(Number(1)) || !values.exists(Number(2))) return 4;
	var found = false;
	for (key in values.keys()) if (key == Pair(1, 2)) found = true;
	if (!found) return 5;
	var tags:Map<GenericTag<Int>, Int> = [];
	tags.set(First, 1); tags.set(Second, 2);
	var count = 0;
	for (tag in tags.keys()) if (tags.exists(tag)) count++;
	return count == 2 ? 42 : 6;
}
