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

	var strings:Array<String> = ["one"];
	var stringsAsDynamic:Dynamic = strings;
	var wrongElementType = false;
	try {
		var unsafe:Array<Dynamic> = cast stringsAsDynamic;
		if (unsafe.length == 1)
			return 4;
	} catch (error:Dynamic) {
		wrongElementType = Std.string(error).indexOf("Array element type mismatch") >= 0;
	}
	if (!wrongElementType)
		return 5;

	var empty:Array<Dynamic> = [];
	var emptyAsDynamic:Dynamic = empty;
	var rejectedEmpty = false;
	try {
		var unsafeEmpty:Array<Item> = cast emptyAsDynamic;
		if (unsafeEmpty.length == 0)
			return 6;
	} catch (error:Dynamic) {
		rejectedEmpty = Std.string(error).indexOf("Array element type mismatch") >= 0;
	}
	return rejectedEmpty ? 42 : 7;
}
