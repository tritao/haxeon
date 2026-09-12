function increment(value:Int):Int {
	return value + 1;
}

function sum9(a:Int, b:Int, c:Int, d:Int, e:Int, f:Int, g:Int, h:Int, i:Int):Int {
	return a + b + c + d + e + f + g + h + i;
}

function main():Int {
	var wrapped:(value:Float) -> Float = cast increment;
	var wrappedStack:(a:Float, b:Float, c:Float, d:Float, e:Float, f:Float, g:Float, h:Float, i:Float) -> Float = cast sum9;
	var one = Std.int(wrapped(41.0));
	var many = Std.int(wrappedStack(1.9, 2.9, 3.9, 4.9, 5.9, 6.9, 7.9, 8.9, 9.9));
	return one == 42 && many == 45 ? 42 : 1;
}
