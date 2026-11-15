class A {
	static function percentile(values:Array<Float>, quantile:Float):Float
		return values[Math.ceil(quantile * values.length) - 1];

	@:keep inline function name<T>(value:T):Map<String, Array<T>>
		return null;

	public function new()
		super();

	function plain():Void {
		var f = function() return 1;
		inner();
	}

	@:native("x") static function native():Int->Void
		return null;
}
