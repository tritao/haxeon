package inventory;

/** One line of stock. */
class Item {
	public final name:String;
	public final category:Category;
	public var count:Int;
	public final price:Float;

	public function new(name:String, category:Category, count:Int, price:Float) {
		this.name = name;
		this.category = category;
		this.count = count;
		this.price = price;
	}

	public function value():Float
		return count * price;

	public function toString():String
		return '$name ($category) x$count';
}

enum abstract Category(String) to String {
	var Fruit = "fruit";
	var Vegetable = "vegetable";
	var Bakery = "bakery";
	var Other = "other";

	public static function parse(text:String):Category
		return switch StringTools.trim(text).toLowerCase() {
			case "fruit": Fruit;
			case "vegetable": Vegetable;
			case "bakery": Bakery;
			case _: Other;
		}
}
