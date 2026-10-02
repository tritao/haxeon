import GcBytes;

// A record's borrowed array field keeps its storage as a root: Wasm GC records the root before the field, gives C
// real addresses at any depth, and copies a record C may write through back without losing the borrowed field.
function main():Int {
	var first = new GcBytes.gc_value_point();
	first.set_x(1);
	first.set_y(2);
	var second = new GcBytes.gc_value_point();
	second.set_x(3);
	second.set_y(4);
	var list = new GcBytes.gc_point_list();
	list.set_points([first, second]);
	if (list.get_count() != 2)
		return 1;
	if (GcBytes.secondY(list) != 4)
		return 2;
	if (GcBytes.secondY(list) != 4)
		return 3;
	var filled = new GcBytes.gc_value_point();
	GcBytes.fillPoint(filled);
	if (filled.get_x() != 7 || filled.get_y() != 9)
		return 4;
	list.set_points([first]);
	return list.get_count() == 1 ? 42 : 5;
}
