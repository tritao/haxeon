enum EscapeValue implements Equatable { Item(value:Int); }

class EnumEscapeCensus {
	static var values:Array<EscapeValue>;
	static var view:Array<Dynamic>;
	public static function prepare():Void {
		values = [EscapeValue.Item(7), EscapeValue.Item(7)];
		view = cast values;
	}
	public static function perform(count:Int):Int {
		var total = 0;
		for (_ in 0...count) {
			var first:Dynamic = values[0], second:Dynamic = view[1];
			if (!(first == second)) return -1;
			total++;
		}
		return total;
	}
}

function main():Int {
	EnumEscapeCensus.prepare();
	if (EnumEscapeCensus.perform(1) != 1) return 1;
	#if !wasm
	var before = hl.Gc.totalAllocated();
	#end
	var result = EnumEscapeCensus.perform(1024);
	#if !wasm
	if (hl.Gc.totalAllocated() != before) return 2;
	#end
	return result == 1024 ? 42 : 3;
}
