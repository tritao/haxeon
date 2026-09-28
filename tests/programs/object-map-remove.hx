import haxe.ds.ObjectMap;

class ObjectKey {
	public final value:Int;

	public function new(value:Int)
		this.value = value;
}

function main():Int {
	var first = new ObjectKey(1);
	var sameValue = new ObjectKey(1);
	var values = new ObjectMap<ObjectKey, Int>();
	if (values.remove(first))
		return 1;
	values.set(first, 7);
	values.set(sameValue, 42);
	if (!values.remove(first) || values.exists(first))
		return 2;
	if (values.remove(first))
		return 3;
	if (!values.exists(sameValue) || values.get(sameValue) != 42)
		return 4;
	if (values.remove(new ObjectKey(1)) || !values.exists(sameValue))
		return 5;
	return 42;
}
