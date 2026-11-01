import compiler.Compiler;
import compiler.ir.IrInterpreter;

/** Declared conformance helpers keep their semantics when the optimizer is toggled. */
class DeclaredEqualityInliningMain {
	static function main():Void {
		var source = 'class Record implements Equatable { public final value:Int; public function new(value:Int) this.value = value; } '
			+ 'class Modulo implements Equatable { public final value:Int; public function new(value:Int) this.value = value; '
			+ 'public function equals(other:Modulo):Bool return value % 10 == other.value % 10; } '
			+ 'struct Scalar : Hashable { public final value:Int; public function new(value:Int) this.value = value; } '
			+ 'function hashOptional(value:Null<Scalar>):Int return haxeon.Hashing.hash(value); '
			+ 'inline function same(left:Record, right:Record):Bool return left == right; '
			+ 'function main():Int { var a = new Record(7); var b = new Record(7); '
			+ 'var c = new Record(8); var optional:Null<Scalar> = new Scalar(5); '
			+ 'return same(a, b) && !same(a, c) && hashOptional(optional) == haxeon.Hashing.hash(new Scalar(5)) '
			+ '&& new Modulo(1) == new Modulo(11) ? 42 : 0; }';
		for (inlineEnabled in [false, true]) {
			var compiler = new Compiler();
			compiler.update("Equatable.hx", "interface Equatable {}\n");
			compiler.update("Hashable.hx", "interface Hashable extends Equatable {}\n");
			compiler.update("haxeon/Hashing.hx", "package haxeon; class Hashing { public static function hash<T:Hashable>(value:T):Int throw \"intrinsic\"; }\n");
			compiler.update("Main.hx", source);
			compiler.configure(inlineEnabled ? "inline-on" : "inline-off", "test",
				["haxeon-inline=" + (inlineEnabled ? "1" : "0")]);
			var result = compiler.compile("Main");
			if (new IrInterpreter(result.ir).run("main") != 42)
				throw 'declared value equality failed with inlining ${inlineEnabled ? "enabled" : "disabled"}';
		}
		Sys.println("PASS: declared conformance equality is stable with inlining enabled and disabled");
	}
}
