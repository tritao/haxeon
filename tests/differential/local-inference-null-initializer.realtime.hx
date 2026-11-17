// `var x = null` takes the nullable of the type of the value first assigned to it, as in Haxe.
class Box {
	public final label:String;

	public function new(label:String)
		this.label = label;
}

class Main {
	static function make(label:String):Box
		return new Box(label);

	static function main():Void {
		var box = null;
		Sys.println(box == null);
		box = make("abcd");
		Sys.println(box.label.length);

		var found = null;
		for (i in 0...10)
			if (i * i > 20 && found == null)
				found = i;
		Sys.println(found);

		var missing = null;
		if (Sys.args().length > 100)
			missing = 1;
		Sys.println(missing == null);

		var text = null;
		text = "t";
		Sys.println(text + "!");
	}
}
