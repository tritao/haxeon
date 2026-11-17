// As in Haxe, a structure whose field is var does not stand for one whose field is final ("Cannot unify final and non-final fields").
typedef Labelled = {
	final label:String;
}

typedef Item = {
	var label:String;
	var count:Int;
}

class Main {
	static function labelOf(item:Labelled):String
		return item.label;

	static function main() {
		var item:Item = {label: "item", count: 1};
		Sys.println(labelOf(item));
	}
}
