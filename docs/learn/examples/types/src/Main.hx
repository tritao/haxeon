interface Named {
	function name():String;
}

class Book implements Named {
	final title:String;

	public function new(title:String) {
		this.title = title;
	}

	public function name():String {
		return title;
	}
}

typedef Shelf = {label:String, count:Int};

function first<T>(items:Array<T>):T {
	return items[0];
}

function main():Void {
	final book:Named = new Book("Atlas");
	final shelf:Shelf = {label: "Maps", count: 2};
	final tags = ["reference", "travel"];
	Sys.println('${shelf.label} (${shelf.count}): ${book.name()}');
	Sys.println(first(tags));
}
