function increment(value:Int):Int {
	return value + 1;
}

function sum9(a:Int, b:Int, c:Int, d:Int, e:Int, f:Int, g:Int, h:Int, i:Int):Int {
	return a + b + c + d + e + f + g + h + i;
}

function sum9Float(a:Float, b:Float, c:Float, d:Float, e:Float, f:Float, g:Float, h:Float, i:Float):Float {
	return a + b + c + d + e + f + g + h + i;
}

function sumMixed(a:Int, b:Float, c:String, d:Int, e:Float, f:String, g:Int, h:Float, i:String):Int {
	return a + Std.int(b) + d + Std.int(e) + g + Std.int(h) + (c == "a" && f == "b" && i == "c" ? 1 : 0);
}

function main():Int {
	var wrapped:(value:Float) -> Float = cast increment;
	var wrappedStack:(a:Float, b:Float, c:Float, d:Float, e:Float, f:Float, g:Float, h:Float, i:Float) -> Float = cast sum9;
	var wrappedFloatStack:(a:Int, b:Int, c:Int, d:Int, e:Int, f:Int, g:Int, h:Int, i:Int) -> Int = cast sum9Float;
	var wrappedMixed:(a:Float, b:Int, c:String, d:Float, e:Int, f:String, g:Float, h:Int, i:String) -> Float = cast sumMixed;
	var one = Std.int(wrapped(41.0));
	var many = Std.int(wrappedStack(1.9, 2.9, 3.9, 4.9, 5.9, 6.9, 7.9, 8.9, 9.9));
	var floatSpill = wrappedFloatStack(1, 2, 3, 4, 5, 6, 7, 8, 9);
	var mixed = Std.int(wrappedMixed(1.9, 2, "a", 3.9, 4, "b", 5.9, 6, "c"));
	return one == 42 && many == 45 && floatSpill == 45 && mixed == 22 ? 42 : 1;
}
