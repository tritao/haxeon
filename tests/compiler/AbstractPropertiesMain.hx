import compiler.Frontend;
import compiler.core.Diagnostic.CompileError;

/**
 * An abstract's variables are properties whose accessors are get/set or never, as in Haxe, which words each error below the
 * same way (tests/differential/abstract-properties*.hx run the accepted forms against it). A static variable is stored in the
 * abstract's storage class (tests/differential/abstract-stati*.hx); a static property with an accessor is not supported yet.
 */
class AbstractPropertiesMain {
	static final STACK = "abstract Stack(Array<Int>) from Array<Int> { ";

	static function main():Void {
		expectError("a variable with storage", STACK + "public var length:Int; }", "",
			"Cannot declare member variable in abstract");
		expectError("a null accessor", STACK + "public var length(get, null):Int; function get_length() return 0; }",
			"",
			"Member property accessors must be get/set or never");
		expectError("a missing getter", STACK + "public var length(get, never):Int; }", "",
			"Method get_length required by property length is missing");
		expectError("a missing setter", STACK + "public var length(never, set):Int; }", "",
			"Method set_length required by property length is missing");
		expectError("an initializer",
			STACK + "public var length(get, never):Int = 3; function get_length() return 0; }", "",
			"on field that is not a real variable");
		expectError("a write of a never property",
			STACK + "public var length(get, never):Int; function get_length() return 0; }",
			"var stack:Stack = [1]; stack.length = 2;", "This expression cannot be accessed for writing");
		expectError("a read of a never property",
			STACK + "public var length(never, set):Int; function set_length(value:Int) return value; }",
			"var stack:Stack = [1]; var length:Int = stack.length;", "This expression cannot be accessed for reading");
		expectError("a private property", STACK + "var length(get, never):Int; function get_length() return 0; }",
			"var stack:Stack = [1]; var length:Int = stack.length;", "Cannot access private field length");
		expectError("a write of a never property from the abstract",
			STACK
			+ "public var length(get, never):Int; function get_length() return 0; public function clear():Void length = 0; }",
			"var stack:Stack = [1]; stack.clear();", "This expression cannot be accessed for writing");
		expectError("a static property",
			STACK + "public static var count(get, never):Int; static function get_count() return 0; }", "",
			'Static property "Stack.count" of an abstract is not supported yet');
		expectError("a write of a static final", STACK + "public static final step:Int = 2; }", "Stack.step = 3;",
			'Final static field "Stack.step" cannot be assigned');
		expectError("a private static", STACK + "static var hidden:Int = 2; }", "var read = Stack.hidden;",
			"Cannot access private field hidden");
		expectError("a missing static", STACK + "public static var count:Int = 0; }", "var read = Stack.missing;",
			'Unknown static field "Stack.missing"');
		// Each access error is at the property's name, where Haxe reports it, not at the receiver.
		var getter = STACK + "public var length(get, never):Int; function get_length() return 0; }";
		expectError("the place of a write", getter, "var stack:Stack = [1]; stack.length = 2;",
			"This expression cannot be accessed for writing", "length = 2");
		expectError("the place of a compound write", getter, "var stack:Stack = [1]; stack.length += 2;",
			"This expression cannot be accessed for writing", "length += 2");
		expectError("the place of a read",
			STACK + "public var length(never, set):Int; function set_length(value:Int) return value; }",
			"var stack:Stack = [1]; var length:Int = stack.length;", "This expression cannot be accessed for reading",
			"length;");
		expectError("the place of a private read",
			STACK + "var length(get, never):Int; function get_length() return 0; }",
			"var stack:Stack = [1]; var count:Int = stack.length;", "Cannot access private field length", "length;");
		Sys.println("PASS: an abstract's properties are checked as Haxe checks them");
	}

	/** Expects `message`, at the first occurrence of `at` in the source when it is given. */
	static function expectError(label:String, declarations:String, body:String, message:String, ?at:String):Void {
		var source = declarations + ' function main():Int { $body return 0; }';
		try {
			Frontend.compile(source);
		} catch (error:CompileError) {
			if (error.diagnostic.message != message)
				throw '$label: expected "$message", got ${error.diagnostic.format()}';
			if (at != null && error.diagnostic.span.start != source.indexOf(at))
				throw '$label: expected the error at "$at" (${source.indexOf(at)}), got ${error.diagnostic.format()}';
			return;
		}
		throw '$label: the source was expected not to compile';
	}
}
