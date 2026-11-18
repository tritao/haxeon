// What a Dynamic index writes into depends on the array, as on HashLink: an array literal written where Dynamic is expected
// holds Dynamic elements (a write past its end leaves nulls, any value can be stored), while a typed array keeps its element
// type behind Dynamic (a write past its end leaves its default, and a value of another type cannot be stored).
class Main {
	static function main():Void {
		var literal:Dynamic = [1, 2];
		literal[4] = 5;
		literal[1] = "x";
		literal[2] = 2.5;
		Sys.println(literal + " " + literal[3] + " " + literal.length);
		var nested:Dynamic = [[1], "a"];
		nested[0][2] = "deep";
		Sys.println(nested);
		var numbers:Array<Int> = [1, 2];
		var typed:Dynamic = numbers;
		typed[4] = 5;
		Sys.println(typed + " " + numbers);
		var words:Array<String> = ["s"];
		var view:Dynamic = words;
		view[2] = "z";
		Sys.println(view);
		var floats:Array<Float> = [1.5];
		var floatView:Dynamic = floats;
		floatView[2] = 2;
		Sys.println(floatView);
		var parsed:Dynamic = haxe.Json.parse('{"items":[1,2]}');
		parsed.items[3] = "w";
		Sys.println(parsed.items);
		try {
			typed[0] = "no";
			Sys.println("stored");
		} catch (error:Dynamic)
			Sys.println("rejected");
	}
}
