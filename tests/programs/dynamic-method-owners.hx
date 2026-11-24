// Exits 42 when dynamic methods rebind through interfaces, abstract statics and generic owners as in Haxe.
interface Transformer<T> {
	dynamic function apply(value:T):T;
}

interface IntTransformer extends Transformer<Int> {}

class Box<T> implements Transformer<T> {
	public function new() {}

	public dynamic function apply(value:T):T {
		return value;
	}
}

class IntBox extends Box<Int> implements IntTransformer {
	override public function apply(value:Int):Int {
		return value + 1;
	}
}

interface Identity {
	dynamic function identity<T>(value:T):T;
}

class GenericIdentity implements Identity {
	public function new() {}

	public dynamic function identity<U>(value:U):U {
		return value;
	}
}

abstract Settings(Int) {
	public static dynamic function adjust(value:Int):Int {
		return value * 2;
	}

	public static function change():Void {
		adjust = value -> value + 9;
	}
}

class Main {
	static function check(actual:String, expected:String):Void {
		if (actual != expected)
			throw 'Expected $expected, got $actual';
	}

	static function main():Void {
		var box = new IntBox();
		var view:IntTransformer = box;
		var original = view.apply;
		check(Std.string(view.apply(3)), "4");
		view.apply = value -> value + 4;
		check(Std.string(box.apply(3)), "7");
		check(Std.string(original(3)), "4");

		var strings = new Box<String>();
		var text:Transformer<String> = strings;
		check(text.apply("old"), "old");
		strings.apply = value -> value + "!";
		check(text.apply("new"), "new!");

		var adjust = Settings.adjust;
		check(Std.string(Settings.adjust(5)), "10");
		Settings.change();
		check(Std.string(Settings.adjust(5)), "14");
		check(Std.string(adjust(5)), "10");
		var generic = new GenericIdentity();
		var identity:Identity = generic;
		check(Std.string(identity.identity(6) + 1), "7");
		check(identity.identity("identity"), "identity");
		var saved:Int->Int = generic.identity;
		identity.identity = (value:Int) -> value + 10;
		check(Std.string(generic.identity(1)), "11");
		check(Std.string(saved(1)), "1");
		Sys.exit(42);
	}
}
