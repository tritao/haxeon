// `var x;` takes its type from the value first assigned to it, wherever that is, as in Haxe.
class Box {
	public final label:String;

	public function new(label:String)
		this.label = label;
}

class Main {
	static function name(flag:Bool):String {
		var name;
		if (flag)
			name = "left";
		else
			name = "right";
		return name;
	}

	static function main():Void {
		Sys.println(name(true) + " " + name(false));

		var box;
		box = new Box("abc");
		Sys.println(box.label.length);

		var count;
		count = 0;
		for (i in 0...5)
			count += i;
		Sys.println(count);

		var total;
		total = 0.5;
		total += 2;
		Sys.println(total);

		var pick;
		var later = () -> pick = "from a lambda";
		pick = "first";
		later();
		Sys.println(pick);
	}
}
