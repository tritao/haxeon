// A static field that holds a function is called as its value is, as in Haxe: directly through the class, with optional
// arguments omitted, and after it is reassigned; and by its bare name inside the class.
class Handlers {
	public static var build:Void->Int = () -> 4;
	public static var scale:(Int, ?Int) -> Int = (value, ?factor) -> value * (factor == null ? 2 : factor);
	public static final label:String->String = name -> "<" + name + ">";
	static var twice:Int->Int = value -> value * 2;

	public static function inside():Int
		return twice(4) + scale(1);
}

function main():Int {
	var total = Handlers.build() + Handlers.scale(3) + Handlers.scale(2, 5);
	Handlers.build = () -> 20;
	total += Handlers.build();
	if (Handlers.label("x") != "<x>" || Handlers.inside() != 8 + 2)
		return 1;
	return total == 4 + 6 + 10 + 20 ? 42 : 2;
}
