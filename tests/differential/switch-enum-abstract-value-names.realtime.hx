// A bare case name is first looked up among the values of the enum abstract the subject holds, so it wins over a
// constructor of the same name in another enum, as an enum's own constructor does.
enum Shape {
	Greater;
	Less;
	Circle(r:Int);
}
enum abstract Op(Int) {
	var Greater = 0;
	var Less = 1;
	var Other = 2;
}
enum abstract Word(String) {
	var Greater = "g";
	var Less = "l";
}
class Main {
	static function describe(op:Op):String
		return switch op {
			case Greater: "gt";
			case Less | Other: "lt-or-other";
			default: "?";
		};
	static function describeNull(op:Null<Op>):String
		return switch op {
			case null: "null";
			case Greater: "gt";
			case Less: "lt";
			case _: "other";
		};
	static function word(w:Word):String
		return switch w {
			case Greater: "G";
			case Less: "L";
			default: "?";
		};
	static function shape(s:Shape):String
		return switch s {
			case Greater: "sg";
			case Less: "sl";
			case Circle(r): "c" + r;
		};
	static function main() {
		Sys.println(describe(Greater) + " " + describe(Less) + " " + describe(Other));
		Sys.println(describeNull(null) + " " + describeNull(Greater) + " " + describeNull(Less) + " "
			+ describeNull(Other));
		Sys.println(word(Greater) + word(Less));
		Sys.println(shape(Greater) + shape(Less) + shape(Circle(3)));
		var pair:{a:Op, b:Shape} = {a: Less, b: Greater};
		Sys.println(switch pair {
			case {
				a:Less, b:Greater
			}
			: "pair";
			default: "no";
		});
	}
}
