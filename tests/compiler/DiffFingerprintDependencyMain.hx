import compiler.Compiler;
import compiler.ir.IrInterpreter;

/** Fingerprinting is self-contained even when the source never imports or calls Hashing. */
class DiffFingerprintDependencyMain {
	static function main():Void {
		for (inlineEnabled in [false, true]) {
			var compiler = new Compiler();
			compiler.update("Diffable.hx", "interface Diffable {}");
			compiler.update("haxeon/Diff.hx", 'package haxeon; class Diff { public static function fingerprint<T:Diffable>(value:T):Int throw "intrinsic"; }');
			compiler.update("Main.hx", 'class Snapshot implements Diffable { public var value:Int; public function new(value:Int) this.value=value; } '
				+ 'function main():Int { var a=new Snapshot(42), b=new Snapshot(43); '
				+ 'var hash=haxeon.Diff.fingerprint(a); '
				+ 'return hash==17*31+42 && haxeon.Diff.fingerprint(b)!=hash ? 42 : 1; }');
			compiler.configure("fingerprint-dependency", "test", ["haxeon-inline=" + (inlineEnabled ? "1" : "0")]);
			if (new IrInterpreter(compiler.compile("Main").ir).run("main") != 42)
				throw "fingerprint required a source Hashing dependency";
		}
		Sys.println("PASS: fingerprint-only callers need no Hashing module with inlining enabled or disabled");
	}
}
