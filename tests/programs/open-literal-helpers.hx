// An object literal's structure is open while its body is typed (docs/design/STRUCTURE_VALUES.md, slice 5): what is generated
// for a type of its own (a generic specialization, an equality or hash helper, a map key's) closes it there first, so its
// name is final when the helper is named.
import haxeon.Equality;
import haxeon.Hashing;

class Bag<T> {
	public var items:Array<T> = [];

	public function new() {}

	public function add<U>(item:T, tag:U):U {
		items.push(item);
		return tag;
	}
}

function first<T>(items:Array<T>):T
	return items[0];

function keep<T>(value:T):Array<T>
	return [value];

function main():Int {
	var point = {x: 1, y: 2};
	var kept = keep(point);
	var total = kept[0].x + first(kept).y;
	var bag = new Bag<{x:Int, y:Int}>();
	var tag = {name: "t"};
	total += bag.add(point, tag).name.length + bag.items.length;
	var listed = [{k: 3}];
	total += first(listed).k;
	var a = {x: 1, y: "a"};
	var b = {x: 1, y: "a"};
	if (Equality.equals(a, b))
		total += 10;
	if (Hashing.hash(a) == Hashing.hash(b))
		total += 10;
	var counts = new Map();
	counts.set(a, 5);
	total += counts.get(b) ?? 0;
	return total + [a, b].indexOf(b) * 9;
}
