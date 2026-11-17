import compiler.Frontend;
import compiler.core.Diagnostic.CompileError;

/**
 * An abstract's variables are properties whose accessors are get/set or never, as in Haxe, which words each error below the
 * same way (tests/differential/abstract-properties*.hx run the accepted forms against it). A static variable of an abstract is
 * not supported yet.
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
		expectError("a static variable", STACK + "public static var count:Int = 0; }", "",
			'Static variable "Stack.count" of an abstract is not supported yet');
		Sys.println("PASS: an abstract's properties are checked as Haxe checks them");
	}

	static function expectError(label:String, declarations:String, body:String, message:String):Void {
		try {
			Frontend.compile(declarations + ' function main():Int { $body return 0; }');
		} catch (error:CompileError) {
			if (error.diagnostic.message != message)
				throw '$label: expected "$message", got ${error.diagnostic.format()}';
			return;
		}
		throw '$label: the source was expected not to compile';
	}
}
