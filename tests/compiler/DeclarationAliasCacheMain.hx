import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceFile;
import compiler.semantic.SemanticSignature;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.DeclarationIndex;
import compiler.types.Type.CompilerType;

/**
 * Alias resolution is memoized per declaration index. These checks pin what the memo must preserve: the
 * resolved types, error reporting for cyclic and broken aliases, generic aliases resolving per argument, and
 * spelling each anonymous shape once per declaration rather than once per mention.
 */
class DeclarationAliasCacheMain {
	static function main():Void {
		var source = new SourceFile("Aliases.hx",
			"package demo;
typedef Inner = {a:Int, b:Float};
typedef Outer = {first:Inner, second:Inner, third:Array<Inner>};
typedef Wrapper<T> = {value:T};
typedef Loop = Loop2;
typedef Loop2 = Loop;
typedef Broken = {x:Missing};
class Marker {}
"),
			tokens = new Lexer(source).tokenize(),
			index = DeclarationIndex.registered(new Parser(tokens).parseProgram());

		var inner = "{a:Int,b:Float}";
		var outer = "{first:" + inner + ",second:" + inner + ",third:Array<" + inner + ">}";

		// A cached result must equal the first, freshly computed one, and show the shape written by hand.
		var before = SemanticSignature.anonymousSpellings;
		var first = index.resolve(AstType.NamedType("Outer"));
		var spelledFirst = SemanticSignature.anonymousSpellings - before;
		var second = index.resolve(AstType.NamedType("Outer"));
		var spelledAgain = SemanticSignature.anonymousSpellings - before - spelledFirst;
		expect(shown(first) == outer, 'resolved alias shape should be exact, got ${shown(first)}');
		expect(spell(second) == spell(first), "a cached alias should resolve to the same type as the first resolution");
		expect(shown(index.resolve(AstType.NamedType("Inner"))) == inner, "a nested alias resolves to its own shape");
		// A structure's name is a digest: it does not grow with the structures nested in it.
		expect(spell(first).length == spell(index.resolve(AstType.NamedType("Inner"))).length,
			'a structure name should not spell its nested structures, got ${spell(first)}');

		// `Inner` is mentioned three times inside `Outer`, but each declaration is spelled once: Inner and Outer.
		expect(spelledFirst == 2, 'Outer and its nested Inner should be spelled once each, spelled $spelledFirst');
		expect(spelledAgain == 0, 'a repeated mention must not spell anything again, spelled $spelledAgain');

		// Generic aliases resolve per argument and never share results across arguments.
		var wrappedInt = index.resolve(AstType.AppliedType("Wrapper", [AstType.IntType]));
		var wrappedFloat = index.resolve(AstType.AppliedType("Wrapper", [AstType.FloatType]));
		var wrappedIntAgain = index.resolve(AstType.AppliedType("Wrapper", [AstType.IntType]));
		expect(shown(wrappedInt) == "{value:Int}", 'Wrapper<Int> should substitute Int, got ${shown(wrappedInt)}');
		expect(shown(wrappedFloat) == "{value:Float}",
			'Wrapper<Float> must not reuse Wrapper<Int>, got ${shown(wrappedFloat)}');
		expect(spell(wrappedFloat) != spell(wrappedInt), "Wrapper<Float> and Wrapper<Int> are named apart");
		expect(spell(wrappedIntAgain) == spell(wrappedInt), "Wrapper<Int> resolves the same way every time");

		// Resolving under a substitution map never disturbs the plain alias.
		var substituted = index.resolve(AstType.NamedType("Inner"), null, ["T" => CompilerType.TFloat]);
		expect(shown(substituted) == inner, "an unrelated substitution should not change a non-generic alias");
		expect(shown(index.resolve(AstType.NamedType("Inner"))) == inner, "the plain alias is unchanged afterwards");

		// Failures throw every time: a cyclic or broken alias is never cached as a value.
		expectError(() -> index.resolve(AstType.NamedType("Loop")), "a cyclic alias should be rejected");
		expectError(() -> index.resolve(AstType.NamedType("Loop")),
			"a cyclic alias should still be rejected on the second try");
		expectError(() -> index.resolve(AstType.NamedType("Broken")),
			"an alias to a missing type should be rejected");
		expectError(() -> index.resolve(AstType.NamedType("Broken")),
			"a broken alias should still be rejected on the second try");
		expect(spell(index.resolve(AstType.NamedType("Outer"))) == spell(first),
			"failures must not disturb cached aliases");

		Sys.println("PASS: alias resolution memoization");
	}

	static function spell(type:CompilerType):String
		return SemanticSignature.type(type);

	static function shown(type:CompilerType):String
		return SemanticSignature.display(type);

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}

	static function expectError(action:Void->Void, message:String):Void {
		var failed = false;
		try
			action()
		catch (_:CompileError)
			failed = true;
		expect(failed, message);
	}
}
