import compiler.Compiler;
import compiler.ir.IrInterpreter;

/** A reference identity call also works when the function is used as a value. */
class ReferenceIdentityMain {
	static function main():Void {
		for (inlineEnabled in [false, true]) {
			var compiler = new Compiler();
			compiler.update("haxeon/reactive/ReactiveIdentity.hx", 'package haxeon.reactive; '
				+ 'extern class ReactiveIdentity { @:hlNative("haxeon_runtime", "__reference_identity") '
				+ 'public static function same(a:Dynamic, b:Dynamic):Bool; }');
			compiler.update("Main.hx", 'import haxeon.reactive.ReactiveIdentity; '
				+ 'class Item { public function new() {} } '
				+ 'function main():Int { var a:Dynamic = new Item(), b:Dynamic = new Item(); '
				+ 'var same:Dynamic->Dynamic->Bool = ReactiveIdentity.same; '
				+ 'var x = new Item(), y = new Item(); var adapted:Item->Item->Bool = ReactiveIdentity.same; '
				+ 'return !ReactiveIdentity.same(a,b) && same(a,a) && !same(a,b) && adapted(x,x) && !adapted(x,y) ? 42 : 0; }');
			compiler.configure("reference-identity", "test", ["haxeon-inline=" + (inlineEnabled ? "1" : "0")]);
			var result = new IrInterpreter(compiler.compile("Main").ir).run("main");
			if (result != 42) throw 'reference identity returned $result (inline=$inlineEnabled)';
		}
		Sys.println("PASS: interpreter reference identity follows object identity");
	}
}
