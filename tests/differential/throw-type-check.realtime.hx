// A throw has every type, as Haxe's Never: a type check or a cast around one is that throw, typed as the target, in an
// expression of that type (a conditional, a return, an argument, a variable).
class Main {
	static function positive(n:Int):Int
		return n > 0 ? n : (throw "not positive: " + n:Int);

	static function named(n:Int):String
		return n == 1 ? "one" : cast(throw 'unnamed $n');

	static function twice(n:Float):Float
		return n * 2;

	static function main() {
		Sys.println(positive(3));
		Sys.println(try positive(-1) catch (e:String) -1);
		Sys.println(named(1));
		Sys.println(try named(2) catch (e:String) e);
		var x:Int = try (throw "s":Int) catch (e:String) 5;
		Sys.println(x);
		Sys.println(try twice((throw 4:Float)) catch (e:Int) e * 10.0);
		var list:Array<Int> = try [1, (throw "in array":Int)] catch (e:String)[];
		Sys.println(list.length);
	}
}
