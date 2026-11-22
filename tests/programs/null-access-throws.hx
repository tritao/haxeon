// A String's length and a Dynamic value's field throw a catchable null access on null, as in Haxe; Reflect.field does not.
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

function fieldOf(value:Dynamic):Dynamic
	return value.name;

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
	var nothing:Dynamic = null;
	count += throwsBoth(() -> fieldOf(nothing), "Null access");
	count += throwsBoth(() -> nothing.name.length, "Null access");
	count += throwsBoth(() -> {
		nothing.name = "set";
		return 0;
	}, "Null access");
	// Reflect.field reads null of null, where a field read throws.
	if (Reflect.field(nothing, "name") == null)
		count++;
	var named:Dynamic = {name: "named"};
	if (fieldOf(named) == "named" && (fieldOf(named):String).length == 5)
		count++;
	return count * 3 + 12;
}
