import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/** A removed source declaration cannot be retained as a generated class on a warm build. */
class RetiredSourceClassMain {
	static final original = 'class P { public static function same(a:Shared,b:Shared):Bool { var x = new Spare(1), y = new Spare(1); '
		+ 'return haxeon.Equality.equals(a,b) && haxeon.Equality.equals(x,y); } } '
		+ 'struct Spare implements Equatable { public final value:Int; public function new(value:Int) this.value=value; }';
	static final replacement = 'class P { public static function same(a:Shared,b:Shared):Bool return true; }';
	static final entry = 'class Main { public static function main():Int { var a=new Shared(1), b=new Shared(1); '
		+ 'return P.same(a,b) && Q.same(a,b) ? 42 : 1; } }';

	static function make(source:String):Compiler {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Shared.hx", 'struct Shared implements Equatable { public final value:Int; public function new(value:Int) this.value=value; }');
		compiler.update("P.hx", source);
		compiler.update("Q.hx", 'class Q { public static function same(a:Shared,b:Shared):Bool return haxeon.Equality.equals(a,b); }');
		compiler.update("Main.hx", entry);
		return compiler;
	}

	static function check(result:compiler.Compiler.CompileResult):Void {
		for (object in result.ir.objects)
			if (object.name == "Spare")
				throw "Removed source class survived as an IR object";
		for (fn in result.ir.functions)
			if (fn.name == "Spare.new")
				throw "Removed source constructor survived in IR";
	}

	static function checkEdit(analyzeFirst:Bool):Void {
		var warm = make(original);
		warm.compile("Main");
		warm.update("P.hx", replacement);
		if (analyzeFirst)
			warm.analyze("Main");
		var updated = warm.compile("Main");
		check(updated);
		if (updated.retyped.indexOf("Q.same") >= 0)
			throw "Editing an unrelated declaration retyped Q.same";
		warm.update("Main.hx", entry + "\n// another edit\n");
		check(warm.compile("Main"));
		check(make(replacement).compile("Main"));
	}

	static function main():Void {
		checkEdit(false);
		checkEdit(true);
		Sys.println("PASS: warm edits discard retired source classes");
	}
}
