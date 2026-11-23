enum Shape {
	Circle(radius:Float);
	Square;
}

class Base {
	public var a:Int = 1;
	var z:String;
	public static var count = 0;

	public function new() {
		z = "z";
	}

	public function m():Int
		return 1;
}

class Child extends Base {
	public var label:String;
	public var size(get, never):Int;
	static final LIMIT = 2;

	public function new(label:String) {
		super();
		this.label = label;
	}

	override public function m():Int
		return 2;

	function get_size():Int
		return label.length;

	public static function make():Child
		return new Child("made");
}

class Main {
	static function main() {
		Sys.println(Type.getClassName(Child) + " " + Type.getClassName(Main) + " " + Type.getClassName(String));
		Sys.println(Type.getEnumName(Shape) + " " + Type.getEnumConstructs(Shape));
		Sys.println(Type.getInstanceFields(Child) + " " + Type.getInstanceFields(Base));
		Sys.println(Type.getClassFields(Child) + " " + Type.getClassFields(Base) + " " + Type.getClassFields(Main));
		var child = Type.createInstance(Child, ["abc"]);
		Sys.println(child.label + " " + child.size + " " + child.m() + " " + child.a);
		var empty = Type.createEmptyInstance(Child);
		Sys.println((empty.label == null) + " " + empty.a + " " + empty.m());
	}
}
