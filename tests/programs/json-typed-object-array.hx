import haxe.Json;

typedef Item = {
	var id:String;
	var type:String;
}

function main():Int {
	var original:Array<Item> = [{id: "first", type: "cad-plate"}];
	var dynamicAlias:Dynamic = original;
	var restored:Array<Item> = cast dynamicAlias;
	if (restored != original || restored[0].id != "first")
		return 1;

	// JSON produces dynamic objects, which are not Item records: the first typed view rejects
	// them before any typed field read.
	var rejected = false;
	try {
		var copied:Array<Item> = Json.parse(Json.stringify(original));
		if (copied[0].type == "cad-plate")
			return 2;
	} catch (error:Dynamic) {
		rejected = Std.string(error).indexOf("Array element type mismatch") >= 0;
	}
	if (!rejected)
		return 3;

	// Array<Dynamic> is a view over any element storage; String values are boxed on read.
	var strings:Array<String> = ["one"];
	var stringsAsDynamic:Dynamic = strings;
	var view:Array<Dynamic> = cast stringsAsDynamic;
	if (view.length != 1 || view[0] != "one")
		return 4;
	view.push("two");
	if (strings.join(",") != "one,two")
		return 5;
	var wrongElementType = false;
	try
		view.push(7)
	catch (error:Dynamic)
		wrongElementType = true;
	if (!wrongElementType || strings.length != 2)
		return 6;

	// Exact storage of one element type is never viewed as another.
	var stringsAsItems = false;
	try {
		var unsafe:Array<Item> = cast stringsAsDynamic;
		if (unsafe.length == 2)
			return 7;
	} catch (error:Dynamic) {
		stringsAsItems = Std.string(error).indexOf("Array element type mismatch: String -> ") >= 0;
	}
	if (!stringsAsItems)
		return 8;

	// Empty dynamic storage takes the element type of its first concrete view.
	var empty:Array<Dynamic> = [];
	var emptyAsDynamic:Dynamic = empty;
	var emptyItems:Array<Item> = cast emptyAsDynamic;
	emptyItems.push({id: "second", type: "cad-shaft"});
	return empty.length == 1 ? 42 : 9;
}
