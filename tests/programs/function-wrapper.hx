function increment(value:Int):Int {
	return value + 1;
}

function sum9(a:Int, b:Int, c:Int, d:Int, e:Int, f:Int, g:Int, h:Int, i:Int):Int {
	return a + b + c + d + e + f + g + h + i;
}

function main():Int {
	var wrapped:(value:Float)->Float = cast increment;
	var wrappedStack:(a:Float, b:Float, c:Float, d:Float, e:Float, f:Float, g:Float, h:Float, i:Float)->Float = cast sum9;
	var one = Std.int(wrapped(41.0));
	var many = Std.int(wrappedStack(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0));
	return one == 42 && many == 45 ? 42 : 1;
}
