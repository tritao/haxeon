// A static field that holds a function is called as its value is, as in Haxe: directly through the class, with optional
// arguments omitted, and after it is reassigned.
class Handlers {
	public static var build:Void->Int = () -> 4;
	public static var scale:(Int, ?Int) -> Int = (value, ?factor) -> value * (factor == null ? 2 : factor);
	public static final label:String->String = name -> "<" + name + ">";
}

function main():Int {
	var total = Handlers.build() + Handlers.scale(3) + Handlers.scale(2, 5);
	Handlers.build = () -> 20;
	total += Handlers.build();
	if (Handlers.label("x") != "<x>")
		return 1;
	return total == 4 + 6 + 10 + 20 ? 42 : 2;
}
