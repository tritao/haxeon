import haxeon.Equality;

typedef GuardRecord = {x:Int, y:Int};

function main():Int {
	var first:GuardRecord = {
		x: 0,
		y: 1
	}, second:GuardRecord = {x: 0, y: 1}, different:GuardRecord = {x: 1, y: 0}, alias:GuardRecord = first;
	var dynamicFirst:Dynamic = first,
		dynamicSecond:Dynamic = second,
		dynamicDifferent:Dynamic = different,
		dynamicAlias:Dynamic = alias;
	if (first == second || first != alias || dynamicFirst == dynamicSecond || dynamicFirst != dynamicAlias)
		return 1;
	if (!Equality.equals(first, second))
		return 2;
	if (Equality.equals(first, different))
		return 3;
	var left:Array<Int> = [1, 2],
		right:Array<Int> = [1, 2],
		unequal:Array<Int> = [1, 3],
		same:Array<Int> = left;
	var dynamicLeft:Dynamic = left,
		dynamicRight:Dynamic = right,
		dynamicUnequal:Dynamic = unequal,
		dynamicSame:Dynamic = same;
	if (left == right || left != same || dynamicLeft == dynamicRight || dynamicLeft != dynamicSame)
		return 4;
	if (!Equality.equals(left, right))
		return 5;
	if (Equality.equals(left, unequal))
		return 6;
	return 42;
}
