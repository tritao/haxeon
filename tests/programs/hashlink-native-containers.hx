import runtime.memory.NativeSlice;
import runtime.memory.NativeVec;

function main():Int {
	var values:NativeVec<Int> = new NativeVec<Int>(2);
	values.push(11);
	values.push(13);
	values.push(17);
	if (values.length != 3 || values.capacity < 3 || values.get(1) != 13)
		return 1;
	var view:NativeSlice<Int> = values.slice();
	var middle:NativeSlice<Int> = view.sub(1, 2);
	middle.set(0, 23);
	if (view.get(1) != 23 || middle.get(1) != 17)
		return 2;
	if (values.pop() != 17 || values.length != 2)
		return 3;
	values.clear();
	try {
		values.pop();
		return 4;
	} catch (_) {}
	values.dispose();
	try {
		values.push(29);
		return 5;
	} catch (_) {}
	return 42;
}
