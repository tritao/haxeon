function main():Int {
	var dynamicNull:Dynamic = cast null;
	var stringNull:String = cast null;
	var optionalNull:Null<Int> = cast null;
	var functionNull:Void->Int = cast null;
	var explicitNull:String = cast(null, String);
	var calls = 0;
	var blockNull:String = cast { calls++; null; };
	var conditionalNull:String = cast (calls == 1 ? null : null);
	var switchNull:String = cast switch (calls) { case 1: {calls++; null;} default: null; };
	if (calls != 2 || blockNull != null || conditionalNull != null || switchNull != null) return 1;
	if (dynamicNull != null || stringNull != null || optionalNull != null || functionNull != null || explicitNull != null)
		return 1;
	#if hl
	var zero:Int = cast null;
	var zeroFloat:Float = cast null;
	var falseValue:Bool = cast null;
	if (zero != 0 || zeroFloat != 0 || falseValue) return 1;
	#end
	var value:Int = cast 40;
	return cast(value + 2, Int);
}
