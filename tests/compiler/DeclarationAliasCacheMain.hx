import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
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
		var source = new SourceFile("Aliases.hx", "package demo;
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

		var inner = "$anon:{a:Int,b:Float}";
		var outer = "$anon:{first:" + inner + ",second:" + inner + ",third:Array<" + inner + ">}";

		// A cached result must equal the first, freshly computed one, and match the spelling by hand.
		var before = SemanticSignature.anonymousSpellings;
		var first = spell(index.resolve(AstType.NamedType("Outer")));
		var spelledFirst = SemanticSignature.anonymousSpellings - before;
		var second = spell(index.resolve(AstType.NamedType("Outer")));
		var spelledAgain = SemanticSignature.anonymousSpellings - before - spelledFirst;
		expect(first == outer, 'resolved alias spelling should be exact, got $first');
		expect(second == first, "a cached alias should resolve to the same type as the first resolution");
		expect(spell(index.resolve(AstType.NamedType("Inner"))) == inner, "a nested alias resolves to its own shape");

		// `Inner` is mentioned three times inside `Outer`, but each declaration is spelled once: Inner and Outer.
		expect(spelledFirst == 2, 'Outer and its nested Inner should be spelled once each, spelled $spelledFirst');
		expect(spelledAgain == 0, 'a repeated mention must not spell anything again, spelled $spelledAgain');

		// Generic aliases resolve per argument and never share results across arguments.
		var wrappedInt = spell(index.resolve(AstType.AppliedType("Wrapper", [AstType.IntType])));
		var wrappedFloat = spell(index.resolve(AstType.AppliedType("Wrapper", [AstType.FloatType])));
		var wrappedIntAgain = spell(index.resolve(AstType.AppliedType("Wrapper", [AstType.IntType])));
		expect(wrappedInt == "$anon:{value:Int}", 'Wrapper<Int> should substitute Int, got $wrappedInt');
		expect(wrappedFloat == "$anon:{value:Float}", 'Wrapper<Float> must not reuse Wrapper<Int>, got $wrappedFloat');
		expect(wrappedIntAgain == wrappedInt, "Wrapper<Int> resolves the same way every time");

		// Resolving under a substitution map never disturbs the plain alias.
		var substituted = index.resolve(AstType.NamedType("Inner"), null, ["T" => CompilerType.TFloat]);
		expect(spell(substituted) == inner, "an unrelated substitution should not change a non-generic alias");
		expect(spell(index.resolve(AstType.NamedType("Inner"))) == inner, "the plain alias is unchanged afterwards");

		// Failures throw every time: a cyclic or broken alias is never cached as a value.
		expectError(function() index.resolve(AstType.NamedType("Loop")), "a cyclic alias should be rejected");
		expectError(function() index.resolve(AstType.NamedType("Loop")), "a cyclic alias should still be rejected on the second try");
		expectError(function() index.resolve(AstType.NamedType("Broken")), "an alias to a missing type should be rejected");
		expectError(function() index.resolve(AstType.NamedType("Broken")), "a broken alias should still be rejected on the second try");
		expect(spell(index.resolve(AstType.NamedType("Outer"))) == outer, "failures must not disturb cached aliases");

		Sys.println("PASS: alias resolution memoization");
	}

	static function spell(type:CompilerType):String
		return SemanticSignature.type(type);

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
