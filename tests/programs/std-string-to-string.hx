class Label {
	public var renders = 0;

	final text:String;

	public function new(text:String)
		this.text = text;

	public function toString():String {
		renders++;
		return "label:" + text;
	}
}

class Loud extends Label {
	public function new(text:String)
		super(text);

	override public function toString():String
		return super.toString().toUpperCase();
}

class Plain {
	public function new() {}
}

// Std.string, concatenation, and interpolation of objects use their toString.
function main():Int {
	var label = new Label("a");
	var described:Dynamic = new Loud("b");
	if (Std.string(label) != "label:a" || "[" + label + "]" != "[label:a]" || '${label}' != "label:a")
		return 1;
	if (Std.string(described) != "LABEL:B" || label.renders != 3)
		return 2;
	if (Std.string(new Plain()) != "Plain")
		return 3;
	if (Std.string(12.7) != "12.7" || Std.string(40.0) != "40"
		|| Std.string(Math.round((0.1 + 0.2) * 1000) / 1000) != "0.3")
		return 4;
	return 42;
}
