import compiler.Frontend;
import compiler.core.Diagnostic.CompileError;

/**
 * An instance field's initializer may not read `this`, nor a member through it (another field, a method, an inherited field, the
 * field itself), not even in a lambda written there: Haxe reports "Cannot access this or other member field in variable
 * initialization" at the first such read. Statics, inline constants and the initializer's own locals are allowed.
 * tests/differential/member-initializer-access.*.hx checks that stock Haxe rejects the same source.
 */
class MemberInitializerAccessMain {
	static inline final MESSAGE = "Cannot access this or other member field in variable initialization";

	static function main():Void {
		// The column is where Haxe reports it: the `this` written, or the member's name.
		expectError("this", "class A { var a = 1; var b = this; }", 30);
		expectError("another field", "class A { var a = 1; var b = a + 1; }", 30);
		expectError("a field through this", "class A { var a = 1; var b = this.a + 1; }", 30);
		expectError("a method", "class A { var b = f(); function f() return 1; }", 19);
		expectError("a field in a lambda", "class A { var a = 1; var b = function() return a; }", 48);
		expectError("this in an arrow lambda", "class A { var a = 1; var b = () -> this.a; }", 36);
		expectError("an inherited field",
			"class B { public var x = 1; public function new() {} } class A extends B { var b = x; }", 84);
		expectError("the field itself", "class A { var b:Int = b; }", 23);
		expectError("a final field", "class A { final a = 1; final b = a; }", 34);
		expectCompiles("statics, inline constants and locals",
			"class A { static var s = 1; static inline var K = 3; static function g() return 1; var a = s + 1; var b = g(); var c = K; "
			+ "var d = { var q = 1; q + 1; }; public function new() {} }");
		Sys.println("PASS: instance field initializers do not read members");
	}

	static function source(classes:String):String
		return classes + " function main():Int return 0;";

	static function expectError(label:String, classes:String, column:Int):Void {
		try {
			Frontend.compile(source(classes));
		} catch (error:CompileError) {
			var diagnostic = error.diagnostic;
			if (diagnostic.message != MESSAGE)
				throw '$label: expected "$MESSAGE", got ${diagnostic.format()}';
			var text = diagnostic.format();
			if (text.indexOf(':1:$column:') < 0)
				throw '$label: expected column $column, got $text';
			return;
		}
		throw '$label: the source was expected not to compile';
	}

	static function expectCompiles(label:String, classes:String):Void {
		try
			Frontend.compile(source(classes))
		catch (error:CompileError)
			throw '$label: ${error.diagnostic.format()}';
	}
}
