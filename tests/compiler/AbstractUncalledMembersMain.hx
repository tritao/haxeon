import compiler.Frontend;
import compiler.core.Diagnostic.CompileError;

/**
 * Every member of an abstract is typed, as Haxe types it, whether or not anything calls it: an error in an instance method or
 * constructor nothing calls is reported, once also when something calls it, and the code of each call is still its own
 * specialization (tests/differential/abstract-uncalled-member*.hx run the same against Haxe).
 */
class AbstractUncalledMembersMain {
	static function main():Void {
		expectErrors("an uncalled method", "abstract A(Int) from Int { public function f():String return this; }", "",
			['Type mismatch for return: expected String, got Int']);
		expectErrors("an uncalled constructor", 'abstract A(Int) { public function new() this = "s"; }', "",
			['Type mismatch for abstract constructor "A.new"']);
		expectErrors("two uncalled methods",
			"abstract A(Int) from Int { public function f():String return this; public function g():Int return missing; }",
			"", ['Type mismatch for return: expected String, got Int', 'Unknown variable "missing"']);
		expectErrors("a called method", "abstract A(Int) from Int { public function f():String return this; }",
			"var a:A = 1; a.f();", ['Type mismatch for return: expected String, got Int']);
		expectErrors("a generic abstract's method",
			"abstract A<T>(Array<T>) from Array<T> { public function f():T return this.length; }", "",
			['Type mismatch for return: expected T, got Int']);
		Frontend.compile("abstract A<T>(Array<T>) from Array<T> { public function first():T return this[0];"
			+ " public function both():Array<T> return [first(), first()]; public function map<U>(f:T->U):Array<U>"
			+ " return [for (value in this) f(value)]; } function main():Int return 0;");
		Sys.println("PASS: an abstract's members are typed whether or not anything calls them");
	}

	static function expectErrors(label:String, declarations:String, body:String, messages:Array<String>):Void {
		try {
			Frontend.compile(declarations + ' function main():Int { $body return 0; }');
		} catch (error:CompileError) {
			var got = [for (diagnostic in error.diagnostics) diagnostic.message];
			if (got.join("\n") != messages.join("\n"))
				throw '$label: expected ${messages.join(" | ")}, got ${error.formatAll()}';
			return;
		}
		throw '$label: the source was expected not to compile';
	}
}
