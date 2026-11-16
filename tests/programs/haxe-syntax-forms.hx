// Haxe forms Haxeon parses as Haxe does: string-named object fields, `catch (e)` without a type, `catch` bodies that end at the
// next `catch` without a semicolon, an arrow function whose body is a loop, and `{}` as an empty object in `c ? a : b`.
function quotedFields():Int {
	var value = {version: 1, "package": {name: "pkg"}, "default": 2};
	return Reflect.field(value, "package").name == "pkg" && Reflect.field(value, "default") == 2
		&& value.version == 1 ? 0 : 1;
}

function untypedCatch():Int {
	var caught = 0;
	try
		throw "boom"
	catch (e)
		caught = 1;
	return caught == 1 ? 0 : 2;
}

function chainedCatchBodies():Int {
	var seen = 0;
	try {
		try
			throw 3
		catch (s:String)
			throw "wrong"
		catch (i:Int)
			throw i + 1
		catch (_:Dynamic) {}
	} catch (n:Int) {
		seen = n;
	}
	return seen == 4 ? 0 : 3;
}

function loopBody():Int {
	var total = 0;
	var sum = (values:Array<Int>) -> for (value in values)
		total += value;
	sum([1, 2, 3]);
	var count = () -> while (total < 10)
		total++;
	count();
	return total == 10 ? 0 : 4;
}

function emptyObjectOperand(empty:Bool):Int {
	var options:Dynamic = empty ? {} : {limit: 5};
	return empty ? (Reflect.fields(options).length == 0 ? 0 : 5) : (options.limit == 5 ? 0 : 6);
}

function main():Int {
	var failure = quotedFields()
		+ untypedCatch()
		+ chainedCatchBodies()
		+ loopBody()
		+ emptyObjectOperand(true)
		+ emptyObjectOperand(false);
	return failure == 0 ? 42 : failure;
}
