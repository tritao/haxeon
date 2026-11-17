class Later {
	public static var total = Earlier.base * 10;
	public static var label = "total " + total;
	public static var ratio = Earlier.half * 2;
}

class Earlier {
	public static var base = 1 + Std.int(2.5);
	public static var half = base / 2;
}

class Main {
	static function main() {
		var total:Int = Later.total;
		var label:String = Later.label;
		var ratio:Float = Later.ratio;
		Sys.println(total > 0);
		Sys.println(StringTools.startsWith(label, "total"));
		Sys.println(ratio >= 0);
	}
}
