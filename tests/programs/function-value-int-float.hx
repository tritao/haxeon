// A function on Float stands for one on Int, and one returning Int for one returning Float, as Haxe unifies Int with Float
// in a function type: an adapter converts the argument and the result.
function half(x:Float):Float
	return x / 2;

function three():Int
	return 3;

function apply(f:Int->Float, value:Int):Float
	return f(value);

function main():Int {
	var halve:Int->Float = half;
	var quarter:Int->Float = (x:Float) -> x / 4;
	var result:Void->Float = three;
	var total = halve(5) + quarter(10) + result() / 2 + apply(half, 7);
	var noFunction:Null<Float->Void> = null;
	var stillNull:Null<Int->Void> = noFunction;
	return stillNull == null && total == 2.5 + 2.5 + 1.5 + 3.5 ? 42 : 1;
}
