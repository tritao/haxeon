import compiler.Frontend;
import compiler.Diagnostic.CompileError;

/**
 * A class's final instance field can only be assigned through `this` in the constructor of the class that declares it, and a static
 * final never: a write through another object, from a method, from a subclass, or by compound assignment or increment is E1026.
 */
class FinalFieldMain {
	static final classes = "class Pair { public final left:Float; public var right:Float; public static final LIMIT:Int = 4; public static var count:Int = 0; "
		+ "public function new(left:Float, right:Float) { this.left = left; this.right = right; } "
		+ "public function mutate():Void { this.right = 1.0; } } "
		+ "class Generic<T> { public final value:T; public function new(value:T) { this.value = value; } } ";

	static function main():Void {
		expectCompiles("assigning a final field in its own constructor, and non-final fields anywhere",
			"var p = new Pair(1.0, 2.0); p.right = 3.0; Pair.count = 5; Pair.count++; p.mutate(); var g = new Generic<Int>(4); return g.value;");
		expectError("a write through another object", "", "var p = new Pair(1.0, 2.0); p.left = 5.0; return 0;");
		expectError("a write through this in a method",
			"class A extends Pair { public function new() { super(1.0, 2.0); } public function breaks():Void { this.left = 1.0; } }",
			"var a = new A(); a.breaks(); return 0;");
		expectError("a compound assignment",
			"class B extends Pair { public function new() { super(1.0, 2.0); } public function grows():Void { this.left += 1.0; } }",
			"var b = new B(); b.grows(); return 0;");
		expectError("a write to another instance's field in a method",
			"class C { public function new() {} public function touch(other:Pair):Void { other.left = 2.0; } }",
			"new C().touch(new Pair(1.0, 2.0)); return 0;");
		expectError("an inherited final field from a subclass constructor",
			"class D extends Pair { public function new() { super(1.0, 2.0); this.left = 9.0; } }", "var d = new D(); return 0;");
		expectError("an increment of a final field", "", "var p = new Pair(1.0, 2.0); p.left++; return 0;");
		expectError("a static final", "", "Pair.LIMIT = 9; return 0;");
		expectError("a static final increment", "", "Pair.LIMIT++; return 0;");
		Sys.println("PASS: final class fields are enforced");
	}

	static function wrap(extra:String, body:String):String
		return classes + extra + " function main():Int { " + body + " }";

	static function expectCompiles(label:String, body:String):Void {
		try {
			Frontend.compile(wrap("", body));
		} catch (error:CompileError) {
			throw '$label failed to compile: ${error.diagnostic.format()}';
		}
	}

	static function expectError(label:String, extra:String, body:String):Void {
		try {
			Frontend.compile(wrap(extra, body));
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1026")
				throw '$label failed with ${error.diagnostic.code} instead of E1026: ${error.diagnostic.format()}';
			return;
		}
		throw '$label unexpectedly compiled';
	}
}
