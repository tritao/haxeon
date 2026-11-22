// A String's length throws a catchable null access on null, as in Haxe.
class Holder {
	public var text:String;
	public var other:Holder;

	public function new(text:String) {
		this.text = text;
	}
}

/** 1 when `read` throws a value `catch (e:Dynamic)` catches and an exception `catch (e:haxe.Exception)` catches. */
function throwsBoth(read:() -> Dynamic, message:String):Int {
	var caught = 0;
	try {
		read();
	} catch (e:Dynamic) {
		caught++;
	}
	try {
		read();
	} catch (e:haxe.Exception) {
		#if !wasm
		// Wasm throws its null accesses without HashLink's message.
		if (e.message != message)
			return 0;
		#end
		caught++;
	}
	return caught == 2 ? 1 : 0;
}

function lengthOf(text:String):Int
	return text.length;

/** The second read of the same string is proven non-null by the first and stays unchecked. */
function twice(text:String):Int
	return text.length + text.length;

function main():Int {
	var count = 0;
	var missing:String = null;
	count += throwsBoth(() -> lengthOf(missing), "Null access .length");
	count += throwsBoth(() -> twice(missing), "Null access .length");
	var holder = new Holder(null);
	count += throwsBoth(() -> holder.text.length, "Null access .length");
	count += throwsBoth(() -> holder.other.text, "Null access .text");
	if (lengthOf("abc") + twice("ab") + new Holder("held").text.length == 11)
		count++;
	return count * 6 + 12;
}
