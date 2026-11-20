// A generic `Array<Null<T>>` argument takes an array of a class, of strings or of `Null<Int>`, binding `T` to the element
// type as Haxe does: `Null<T>` meets a value that is not nullable too.
class Block {
	public var id:Int;

	public function new(id)
		this.id = id;
}

class Main {
	static function count<T>(a:Array<Null<T>>):Int {
		var n = 0;
		for (x in a)
			if (x != null)
				n++;
		return n;
	}

	static function first<T>(a:Array<Null<T>>):Null<T>
		return a.length > 0 ? a[0] : null;

	static function orNull<T>(value:Null<T>):Array<Null<T>>
		return [value, null];

	static function main() {
		var blocks:Array<Block> = [new Block(1), null, new Block(3)];
		Sys.println(count(blocks));
		var b = first(blocks);
		if (b != null)
			Sys.println(b.id);
		var names = ["a", null];
		Sys.println(count(names));
		var nullable:Array<Null<Int>> = [1, null];
		Sys.println(count(nullable));
		Sys.println(first(nullable));
		var empty:Array<Block> = [];
		Sys.println(first(empty) == null);
		Sys.println(count([new Block(2)]));
		Sys.println(count(orNull(new Block(9))));
		Sys.println(orNull(4));
		Sys.println(orNull("s").length);
	}
}
