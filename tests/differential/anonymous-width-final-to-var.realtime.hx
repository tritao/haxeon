// A final field cannot stand for a writable one: Haxe reports "Inconsistent setter for field label".
typedef Writable = {
	var label:String;
}

typedef Item = {
	final label:String;
	final count:Int;
}

class Main {
	static function rename(item:Writable):Void
		item.label = "renamed";

	static function main() {
		var item:Item = {label: "item", count: 1};
		rename(item);
		Sys.println(item.label);
	}
}
