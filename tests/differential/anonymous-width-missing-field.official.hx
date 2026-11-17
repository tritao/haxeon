// Width subtyping drops fields but never invents one: a structure without `note` is no Labelled, even though `note` is optional.
typedef Labelled = {
	final label:String;
	@:optional final note:String;
}

typedef Item = {
	final label:String;
	final count:Int;
}

class Main {
	static function labelOf(item:Labelled):String
		return item.label;

	static function main() {
		var item:Item = {label: "item", count: 1};
		Sys.println(labelOf(item));
	}
}
