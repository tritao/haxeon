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
		// A plain abstract has exactly its representation's equality: never more.
		rejected('class Ref { public function new() {} } abstract Handle(Ref) { public inline function new(ref:Ref) this = ref; } function main():Int { var a:Array<Handle> = []; var b:Array<Handle> = []; return haxeon.Equality.equals(a, b) ? 1 : 0; }',
			"Equatable");
		rejected('struct S { public final value:Int; public function new(value:Int) this.value = value; } abstract Wrapped(S) { public inline function new(value:S) this = value; } function main():Int { var a:Array<Wrapped> = []; var b:Array<Wrapped> = []; return haxeon.Equality.equals(a, b) ? 1 : 0; }',
			"Equatable");
		Sys.println("PASS: nonconforming value equality and hashing report E1025");
	}

	static function rejected(source:String, capability:String):Void {
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
			|| diagnostic.diagnostic.message.indexOf('does not conform to $capability') < 0)
			throw 'Expected E1025 does not conform to $capability, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}
}
