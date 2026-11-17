// `throw null` throws a null Dynamic, as Haxe does on HashLink: `catch (e:Dynamic)` and `catch (e:Any)` bind null, a
// catch of haxe.Exception (or ValueException) gets a ValueException of null, and a catch of any other type lets it
// through. (Uncaught, both print "Uncaught exception: null".)
class Main {
	static function thrower():Void
		throw null;

	static function value(fail:Bool):Int {
		if (fail)
			throw null;
		return 1;
	}

	static function main() {
		try
			throw null
		catch (e:Dynamic)
			Sys.println("dynamic " + e + " " + (e == null));
		try
			throw null
		catch (e:String)
			Sys.println("string " + e)
		catch (e:Dynamic)
			Sys.println("past string " + e);
		try
			throw null
		catch (e:haxe.Exception)
			Sys.println("exception [" + e.message + "] " + Std.isOfType(e, haxe.ValueException) + " " + e.toString());
		try {
			try
				thrower()
			catch (e:Int)
				Sys.println("int " + e);
		} catch (e:Any)
			Sys.println("any " + e);
		try {
			try
				throw null
			catch (e:haxe.ValueException)
				Sys.println("value exception " + e.value);
		} catch (e:Dynamic)
			Sys.println("outer " + e);
		try {
			try
				value(true)
			catch (e:Dynamic) {
				Sys.println("rethrow " + e);
				throw e;
			}
		} catch (e:Dynamic)
			Sys.println("rethrown " + e);
		var x:Int = try {
			throw null;
		} catch (e:Dynamic) 5;
		Sys.println(x + value(false));
	}
}
