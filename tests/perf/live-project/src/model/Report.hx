package model;

class Report {
	public static function describe(counter:Counter):String
		return "total " + label(counter.total);

	static function label(value:Int):String
		return Std.string(value);
}
