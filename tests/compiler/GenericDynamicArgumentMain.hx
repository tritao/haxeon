import compiler.Frontend;

/** A generic type with a concrete argument is accepted where the same type with a Dynamic argument is expected, and no more than that. */
class GenericDynamicArgumentMain {
	static final prelude = 'class Box<T> { public var value:T; public function new(value:T) this.value = value; }
class IntBox extends Box<Int> { public function new(value:Int) super(value); }
interface Source<T> { function next():T; }
class Counter implements Source<Int> { public function new() {} public function next():Int return 1; }
';

	static function accepts(body:String, message:String):Void {
		try {
			Frontend.compile(prelude + "function main():Int { " + body + " return 0; }");
		} catch (error:Dynamic) {
			throw message + ": " + Std.string(error);
		}
	}

	static function rejects(body:String, message:String):Void {
		var failure:Null<String> = null;
		try {
			Frontend.compile(prelude + "function main():Int { " + body + " return 0; }");
		} catch (error:Dynamic) {
			failure = Std.string(error);
		}
		if (failure == null || failure.indexOf("E1002") < 0)
			throw message + (failure == null ? ": it compiled" : ": " + failure);
	}

	static function main():Void {
		accepts("var box:Box<Dynamic> = new Box<Int>(1);", "a primitive argument");
		accepts("var box:Box<Dynamic> = new Box<String>('a');", "a reference argument");
		accepts("var box:Box<Dynamic> = new IntBox(1);", "through a base class that supplies the argument");
		accepts("var source:Source<Dynamic> = new Counter();", "through an implemented interface");
		accepts("var box:Null<Box<Dynamic>> = new Box<Int>(1);", "into a nullable");
		accepts("function take(box:Box<Dynamic>):Void {} take(new Box<Int>(1));", "as an argument");

		// Only a whole Dynamic argument on the expected side widens.
		rejects("var box:Box<String> = new Box<Int>(1);", "different concrete arguments");
		rejects("var box:Box<Int> = new Box<Dynamic>(1);", "Dynamic where a concrete argument is expected needs a cast");
		rejects("var box:Box<Array<Dynamic>> = new Box<Array<Int>>([1]);", "Dynamic nested inside an argument");
		Sys.println("PASS: a Dynamic type argument accepts any argument, and nothing else widens");
	}
}
