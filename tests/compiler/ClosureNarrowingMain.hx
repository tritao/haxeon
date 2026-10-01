import compiler.Compiler;

/**
 * Calling a closure makes the typer forget what it knew about a captured variable that is written somewhere,
 * because the call may assign it. A closure that is known (a lambda called where it is written, or a local
 * function that is never reassigned) only forgets the variables it can assign, so reading a narrowed
 * variable after a call to a closure that only reads it is fine; anything that may assign it still is not.
 */
class ClosureNarrowingMain {
	static function main():Void {
		// Each body follows `var o:Null<Layout> = seed; if (o == null) o = {yaw: 1.0};`, so `o` is narrowed to an
		// object and, being captured by the closure and written above, is one the closure call would forget.
		var kept = [
			"a known local function that only reads" => "var g = function() return o.yaw; return g() + o.yaw;",
			"a lambda called in place that only reads" => "var v = (function() { return o.yaw; })(); return v + o.yaw;",
			"a closure that captures a copy" => "var c = o; var g = function() return c.yaw; return g() + o.yaw;",
			"a known local function that calls another reader" => "var r = function() return o.yaw; var g = function() return r(); return g() + o.yaw;",
			"a closure that calls a function it was handed, which cannot reach this function's locals" =>
			"var g = function() { cb(); return 1.0; }; var v = g(); return v + o.yaw;"
		];
		for (description => body in kept)
			expect(analyse(body) == null, 'The narrowing of a captured variable must survive a call to $description, got: ${analyse(body)}');
		var forgotten = [
			"a known local function that assigns it" => "var g = function() { o = null; return 1.0; }; var v = g(); return o.yaw;",
			"a lambda called in place that assigns it" => "var v = (function() { o = null; return 1.0; })(); return o.yaw;",
			"a local function that calls one that assigns it" =>
			"var w = function() { o = null; }; var g = function() { w(); return 1.0; }; var v = g(); return o.yaw;",
			"a local function that hands one that assigns it on" =>
			"var w = function() { o = null; }; var g = function() { var z = w; return 1.0; }; var v = g(); return o.yaw;",
			"a local function that defines and calls a nested one that assigns it" =>
			"var g = function() { var inner = function() { o = null; }; inner(); return 1.0; }; var v = g(); return o.yaw;",
			"a local function that calls a method, which may run a stored closure" =>
			"var h = { run: function() { o = null; } }; var g = function() { h.run(); return 1.0; }; var v = g(); return o.yaw;",
			"a function value whose body is not known" => "var k:() -> Float = function() { o = null; return 1.0; }; var v = k(); return o.yaw;",
			"a local function that is reassigned" => "var g:(Int) -> Float = null; g = function(n:Int) { o = null; return 1.0; }; var v = g(2); return o.yaw;"
		];
		for (description => body in forgotten)
			expect(analyse(body) != null && analyse(body).indexOf("requires an object") >= 0,
				'The narrowing of a captured variable must be forgotten after a call to $description, got: ${analyse(body)}');
		Sys.println("PASS: calling a closure forgets only the captured variables it can assign");
	}

	/** The first diagnostic from analysing a function with `body`, or null when it analyses cleanly. */
	static function analyse(body:String):Null<String> {
		var compiler = new Compiler();
		compiler.update("Main.hx",
			"typedef Layout = { yaw:Float };\nfunction f(seed:Null<Layout>, cb:() -> Void):Float {\n  var o:Null<Layout> = seed;\n  if (o == null) o = { yaw: 1.0 };\n" +
			body + "\n}\nfunction main():Int return 0;");
		try {
			compiler.analyze("Main");
			return null;
		} catch (error:Dynamic) {
			return Std.string(error).split("\n")[0];
		}
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
