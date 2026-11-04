import compiler.Compiler;
import compiler.ir.IrInterpreter;

/** Declared conformance helpers keep their semantics when the optimizer is toggled. */
class DeclaredEqualityInliningMain {
	static function main():Void {
		var source = 'class Record implements Equatable { public final value:Int; public function new(value:Int) this.value = value; } '
			+ 'class Modulo implements Equatable { public final value:Int; public function new(value:Int) this.value = value; '
			+ 'public function equals(other:Modulo):Bool return value % 10 == other.value % 10; } '
			+ 'struct Scalar implements Hashable { public final value:Int; public function new(value:Int) this.value = value; } '
			+ 'class Snapshot implements Diffable { public var value:Int; public function new(value:Int) this.value = value; } '
			+ 'class Parent { public final base:Int; public function new(base:Int) this.base = base; } '
			+ 'class Child extends Parent implements Hashable { public final child:Int; public function new(base:Int, child:Int) { super(base); this.child = child; } } '
			+ 'class CustomBase implements Equatable { public final value:Int; public function new(value:Int) this.value = value; public function equals(other:CustomBase):Bool return value % 10 == other.value % 10; } '
			+ 'class CustomChild extends CustomBase { public function new(value:Int) super(value); } '
			+ 'function hashOptional(value:Null<Scalar>):Int return haxeon.Hashing.hash(value); '
			+ 'inline function snapshotFingerprint(value:Snapshot):Int return haxeon.Diff.fingerprint(value); '
			+ 'inline function same(left:Record, right:Record):Bool return left == right; '
			+ 'function main():Int { var a = new Record(7); var b = new Record(7); '
			+ 'var c = new Record(8); var optional:Null<Scalar> = new Scalar(5); '
			+ 'var snapshot = new Snapshot(4); var sameSnapshot = new Snapshot(4); var changedSnapshot = new Snapshot(5); '
			+ 'return same(a, b) && !same(a, c) && hashOptional(optional) == haxeon.Hashing.hash(new Scalar(5)) '
			+ '&& snapshotFingerprint(snapshot) == snapshotFingerprint(sameSnapshot) '
			+ '&& snapshotFingerprint(snapshot) != snapshotFingerprint(changedSnapshot) '
			+ '&& new Modulo(1) == new Modulo(11) && new CustomChild(1) == new CustomChild(11) '
			+ '&& new Child(1, 7) != new Child(2, 7) && haxeon.Hashing.hash(new Child(1, 7)) != haxeon.Hashing.hash(new Child(2, 7)) ? 42 : 0; }';
		for (inlineEnabled in [false, true]) {
			var compiler = new Compiler();
			compiler.update("Equatable.hx", "interface Equatable {}\n");
			compiler.update("Hashable.hx", "interface Hashable extends Equatable {}\n");
			compiler.update("Diffable.hx", "interface Diffable {}\n");
			compiler.update("haxeon/Diff.hx", "package haxeon; class Diff { public static function fingerprint<T:Diffable>(value:T):Int throw \"intrinsic\"; }\n");
			compiler.update("haxeon/Hashing.hx", "package haxeon; class Hashing { public static function hash<T:Hashable>(value:T):Int throw \"intrinsic\"; public static function mix(hash:Int, value:Int):Int return hash * 31 + value; }\n");
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
