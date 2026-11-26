using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;

/** Explicit value equality must never silently compare an unsupported type by identity. */
class EqualityConformanceMain {
	static function main():Void {
		rejected('class Ref { public function new() {} } function main():Int { var a = new Ref(); var b = new Ref(); return haxeon.Equality.equals(a, b) ? 1 : 0; }',
			"Equatable");
		rejected('class Ref { public function new() {} } function main():Int { var a:Array<Ref> = []; var b:Array<Ref> = []; return haxeon.Equality.equals(a, b) ? 1 : 0; }',
			"Equatable");
		rejected('enum E { Item(value:Int); } function main():Int return haxeon.Equality.equals(Item(1), Item(1)) ? 1 : 0;',
			"Equatable");
		rejected('class Ref { public function new() {} } function main():Int return haxeon.Hashing.hash(new Ref());',
			"Hashable");
		rejected('struct S { public final value:Int; public function new(value:Int) this.value = value; } function main():Int return new S(1) == new S(1) ? 1 : 0;',
			"Equatable");
		rejected('struct S { public final value:Int; public function new(value:Int) this.value = value; } function main():Int { var a:Array<S> = [new S(1)]; return switch a { case [new S(1)]: 42; default: 0; }; }',
			"Equatable");
		rejected('function main():Int { var map:Map<Array<Int>, Int> = []; return 0; }', "Hashable");
		rejected('class Ref { public function new() {} } abstract Wrapped(Ref) { public inline function new(value:Ref) this = value; } function main():Int return haxeon.Equality.equals(new Wrapped(new Ref()), new Wrapped(new Ref())) ? 42 : 0;',
			"Equatable");
		rejected('class Ref { public function new() {} } abstract Handle(Ref) { public inline function new(ref:Ref) this = ref; } function main():Int { var a:Array<Handle> = []; var b:Array<Handle> = []; return haxeon.Equality.equals(a, b) ? 1 : 0; }',
			"Equatable");
		rejected('struct S { public final value:Int; public function new(value:Int) this.value = value; } abstract Wrapped(S) { public inline function new(value:S) this = value; } function main():Int { var a:Array<Wrapped> = []; var b:Array<Wrapped> = []; return haxeon.Equality.equals(a, b) ? 1 : 0; }',
			"Equatable");
		var custom =
			'abstract Custom(Int) { public inline function new(value:Int) this = value; @:op(A == B) public static function equal(a:Custom, b:Custom):Bool return true; } ';
		rejected(custom + 'function main():Int return haxeon.Equality.equals(new Custom(1), new Custom(2)) ? 42 : 0;',
			"Equatable", "custom == operator");
		rejected(custom
			+ 'function main():Int { var a:Array<Custom> = [new Custom(1)]; return haxeon.Equality.equals(a, a) ? 42 : 0; }',
			"Equatable",
			"custom == operator");
		rejected(custom + 'function main():Int { var values:Map<Custom, Int> = []; return 42; }', "Hashable",
			"custom == operator");
		operatorEditsMatchCold();
		Sys.println("PASS: nonconforming value equality and hashing report E1025");
	}

	static function operatorSource(custom:Bool):String {
		var annotation = custom ? "@:op(A == B)" : "";
		return 'abstract Id(Int) { public inline function new(value:Int) this = value; $annotation public static function eq(a:Id, b:Id):Bool return true; }';
	}

	static function operatorCompiler(custom:Bool):Compiler {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Id.hx", operatorSource(custom));
		compiler.update("Main.hx", 'function main():Int return haxeon.Equality.equals(new Id(1), new Id(1)) ? 42 : 0;');
		return compiler;
	}

	static function operatorEditsMatchCold():Void {
		var warm = operatorCompiler(false);
		warm.compile("Main");
		warm.update("Id.hx", operatorSource(true));
		for (compiler in [warm, operatorCompiler(true)]) {
			var diagnostic:Null<CompileError> = null;
			try
				compiler.compile("Main")
			catch (error:CompileError)
				diagnostic = error;
			if (diagnostic == null
				|| diagnostic.diagnostic.code != "E1025"
				|| diagnostic.diagnostic.message.indexOf("custom == operator") < 0)
				throw 'Expected custom == E1025, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
		}
		warm.update("Id.hx", operatorSource(false));
		var warmBytes = warm.compile("Main").artifact.hashLink().hashLinkBytes().flatten();
		var coldBytes = operatorCompiler(false).compile("Main").artifact.hashLink().hashLinkBytes().flatten();
		if (warmBytes.compare(coldBytes) != 0)
			throw "Warm and cold modules differ after removing custom ==";
	}

	static function rejected(source:String, capability:String, ?detail:String):Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx", source);
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null
			|| diagnostic.diagnostic.code != "E1025"
			|| diagnostic.diagnostic.message.indexOf('does not conform to $capability') < 0
			|| (detail != null && diagnostic.diagnostic.message.indexOf(detail) < 0))
			throw 'Expected E1025 does not conform to $capability, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}
}
