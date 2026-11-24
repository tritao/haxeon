// An array method on a null array throws a catchable null access, as in Haxe, on every element storage.
class Item {
	public var id:Int;

	public function new(id:Int) {
		this.id = id;
	}
}

/** 1 when `use` throws a null access that `catch (e:haxe.Exception)` catches. */
function throws(use:() -> Void):Int {
	try {
		use();
	} catch (e:haxe.Exception) {
		#if !wasm
		// Wasm throws its null accesses without HashLink's message. Stock Haxe names the method in some ("Null access .resize").
		if (!StringTools.startsWith(e.message, "Null access"))
			return 0;
		#end
		return 1;
	}
	return 0;
}

/** The array is proven non-null by the first call, so the second is unchecked. */
function resizeTwice(values:Array<Int>):Int {
	values.resize(2);
	values.resize(3);
	return values.length;
}

function main():Int {
	var ints:Array<Int> = null;
	var floats:Array<Float> = null;
	var texts:Array<String> = null;
	var flags:Array<Bool> = null;
	var items:Array<Item> = null;
	var dynamics:Array<Dynamic> = null;
	var count = 0;
	count += throws(() -> ints.resize(3));
	count += throws(() -> ints.unshift(1));
	count += throws(() -> ints.insert(0, 1));
	count += throws(() -> ints.pop());
	count += throws(() -> ints.shift());
	count += throws(() -> ints.remove(1));
	count += throws(() -> ints.indexOf(1));
	count += throws(() -> ints.reverse());
	count += throws(() -> ints.copy());
	count += throws(() -> ints.slice(0, 1));
	count += throws(() -> ints.splice(0, 1));
	count += throws(() -> ints.concat([1]));
	count += throws(() -> resizeTwice(ints));
	count += throws(() -> floats.resize(2));
	count += throws(() -> floats.indexOf(1.5));
	count += throws(() -> texts.join(","));
	count += throws(() -> texts.remove("a"));
	count += throws(() -> flags.pop());
	count += throws(() -> items.resize(1));
	count += throws(() -> items.shift());
	count += throws(() -> items.slice(1));
	count += throws(() -> dynamics.reverse());
	count += throws(() -> dynamics.unshift(1));
	var present = [1, 2, 3];
	if (resizeTwice(present) == 3 && present[2] == 0)
		count++;
	return count + 18;
}
