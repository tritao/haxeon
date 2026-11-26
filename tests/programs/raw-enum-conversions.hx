// Raw-value enums: codes of a 32-case table, an Int set with a high code and a String set; rawValue and fromRaw() in
// fields, arrays, structs and exposed functions.
enum Code32:Int {
	Case0 = 0;
	Case1 = 1;
	Case2 = 2;
	Case3 = 3;
	Case4 = 4;
	Case5 = 5;
	Case6 = 6;
	Case7 = 7;
	Case8 = 8;
	Case9 = 9;
	Case10 = 10;
	Case11 = 11;
	Case12 = 12;
	Case13 = 13;
	Case14 = 14;
	Case15 = 15;
	Case16 = 16;
	Case17 = 17;
	Case18 = 18;
	Case19 = 19;
	Case20 = 20;
	Case21 = 21;
	Case22 = 22;
	Case23 = 23;
	Case24 = 24;
	Case25 = 25;
	Case26 = 26;
	Case27 = 27;
	Case28 = 28;
	Case29 = 29;
	Case30 = 30;
	Case31 = 31;
}
enum abstract OpenBits(Int) from Int to Int {
	var One = 1;
	var Two = 2;
}
enum Code:Int {
	Zero = 0;
	Red = 4;
	Blue = 7;
	High = 0x7fffffff;
}
enum Mime:String {
	Json = "application/json";
	Text = "text/plain";
}
struct Pair {
	public final code:Code;
	public final value:Int;
	public function new(code:Code, value:Int) {
		this.code = code;
		this.value = value;
	}
}
class Holder {
	public var code:Code;
	public function new(code:Code) this.code = code;
}
class Probe {
	@:expose public static function fromRaw32(count:Int):Int {
		var total = 0;
		for (index in 0...count) {
			var value = Code32.fromRaw(index & 31);
			if (value == null) return -1;
			total += value.rawValue;
		}
		return total;
	}
	@:expose public static function raw(count:Int):Int {
		var total = 0;
		for (index in 0...count) total += Code.Red.rawValue + Code.Blue.rawValue;
		return total;
	}
}
function main():Int {
	if (Probe.fromRaw32(32) != 496 || Code32.fromRaw(32) != null) return 12;
	var bits:OpenBits = OpenBits.One | OpenBits.Two;
	if (bits != 3) return 10;
	var code:Code = Code.Red;
	if (code != Code.Red || code.rawValue != 4) return 1;
	var values:Array<Code>= [Code.Red, Code.Blue];
	if (values[1].rawValue != 7 || values.indexOf(Code.Blue) != 1) return 2;
	var strings:Array<Mime>= [Mime.Text];
	if (strings.indexOf(Mime.Text) != 0 || strings.join(",") != "text/plain") return 13;
	values[OpenBits.One] = Code.Red;
	if (values[OpenBits.One] != Code.Red) return 14;
	values[OpenBits.One] = Code.Blue;
	var holder = new Holder(Code.Blue);
	if (holder.code != Code.Blue) return 3;
	var pair = new Pair(Code.Red, 38);
	if (pair.code.rawValue + pair.value != 42) return 4;
	var zero = Code.fromRaw(0);
	if (zero == null || zero.rawValue != 0) return 11;
	var known = Code.fromRaw(7);
	if (known == null || known != Code.Blue || known.rawValue != 7) return 5;
	if (Code.fromRaw(99) != null || Code.fromRaw(-1) != null) return 6;
	var text = Mime.fromRaw("text/plain");
	if (text == null || text != Mime.Text || text.rawValue != "text/plain") return 7;
	if (Mime.fromRaw("unknown") != null) return 8;
	if (Probe.raw(2) != 22) return 9;
	return 42;
}
