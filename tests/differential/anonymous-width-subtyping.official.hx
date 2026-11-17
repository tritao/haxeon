// A structure with more fields stands for one with fewer (Haxe's width subtyping), here between typedef'd structures
// whose fields are final: as an argument, a local, a return value, a nested field, a nullable and an array element.
// A known divergence: Haxeon rejects it until structures are lowered as views of one object
// (docs/design/STRUCTURE_VALUES.md, step 4); tests/differential/run.sh fails once it compiles.
typedef Arm = {
	final value:Int;
	final guard:Null<String>;
	final label:String;
}

typedef Case = {
	final value:Int;
	final guard:Null<String>;
	final label:String;
	final statements:Array<String>;
	final enumName:String;
}

typedef Point = {
	final x:Float;
	final y:Float;
}

typedef Pixel = {
	final x:Int;
	final y:Int;
	final color:String;
}

typedef Shape = {
	final name:String;
	final origin:Point;
}

typedef Sprite = {
	final name:String;
	final origin:Pixel;
	final frames:Int;
}

typedef Labelled = {
	final label:String;
	@:optional final note:String;
}

typedef Noted = {
	final label:String;
	final note:String;
	final extra:Int;
}

class Main {
	static function armOf(arm:Arm):String
		return '${arm.value} ${arm.guard} ${arm.label}';

	static function narrow(item:Case):Arm
		return item;

	static function maybe(arm:Null<Arm>):String
		return arm == null ? "none" : arm.label;

	static function describe(shape:Shape):String
		return '${shape.name} at ${shape.origin.x},${shape.origin.y}';

	static function labelOf(item:Labelled):String
		return item.note == null ? item.label : '${item.label} (${item.note})';

	static function main() {
		var item:Case = {
			value: 1,
			guard: null,
			label: "first",
			statements: ["a", "b"],
			enumName: "Kind"
		};
		Sys.println(armOf(item));
		var arm:Arm = item;
		Sys.println(arm.label + " " + narrow(item).value);
		var nullableItem:Null<Case> = item, missing:Null<Case> = null;
		Sys.println(maybe(nullableItem) + " " + maybe(missing));
		var arms:Array<Arm> = [item, {value: 2, guard: "g", label: "second"}];
		Sys.println(arms.map(a -> armOf(a)).join("; "));
		// A final field converts as its type does: Int to Float, and a nested structure by width.
		var sprite:Sprite = {name: "hero", origin: {x: 3, y: 4, color: "red"}, frames: 2};
		Sys.println(describe(sprite));
		var view = (a:Arm) -> a.value * 10;
		Sys.println(view(item));
		// An optional field may come from a required one.
		var noted:Noted = {label: "noted", note: "kept", extra: 1};
		Sys.println(labelOf(noted));
	}
}
