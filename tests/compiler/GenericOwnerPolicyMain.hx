import compiler.Source.SourceFile;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Type.CompilerType;
import compiler.types.typing.TypingSession;

/** Owner identity must be stable across sessions and retain the layouts it uses. */
class GenericOwnerPolicyMain {
	static function main():Void {
		var source = 'struct First { public var value:Int; } struct Second { public var value:Int; } '
			+ 'class Reference {} class OtherReference {} '
			+ 'class Box<T, U> { public var value:T; public var reference:U; } '
			+ 'class Nested<T, U> { public var value:T; public var references:Array<U>; } '
			+ 'class Parent<T> {} class Derived<T, U> extends Parent<U> { public var value:T; } '
			+ 'class Recursive<T> { public var next:Recursive<Array<T>>; } '
			+ 'function main():Int return 42;';
		var syntax = new Parser(new Lexer(new SourceFile("OwnerPolicy.hx", source)).tokenize()).parseProgram(),
			semantic = SemanticProgram.analyze(syntax), names = new GenericSpecializationRegistry(),
			first = session(semantic, names),
			firstValue = instance("First"), secondValue = instance("Second"),
			reference = instance("Reference"), otherReference = instance("OtherReference");
		var box = first.representation.genericOwner(instance("Box", [firstValue, reference]));
		if (box == null || box.policies.join(",") != "layout,shape" || !Type.enumEq(box.typeArguments[0], firstValue)
			|| !Type.enumEq(box.typeArguments[1], TDynamic)) throw "incorrect owner substitutions";
		var same = first.representation.genericOwner(instance("Box", [firstValue, otherReference]));
		if (same != box || first.representation.genericOwnerRequestCount() != 1) throw "owner shape was not shared";
		var other = first.representation.genericOwner(instance("Box", [secondValue, reference]));
		if (other == null || other.name == box.name) throw "different value layouts shared an owner";
		var nested = first.representation.genericOwner(instance("Nested", [firstValue, reference]));
		if (nested == null || nested.policies.join(",") != "layout,layout" || !Type.enumEq(nested.typeArguments[1], reference))
			throw "nested field erased its element representation";
		var inherited = first.representation.genericOwner(instance("Derived", [firstValue, reference]));
		if (inherited == null || inherited.policies.join(",") != "layout,layout") throw "generic base erased its argument";
		if (first.representation.genericOwner(instance("Box", [reference, otherReference])) != null)
			throw "reference-only owner should retain its existing shared representation";
		if (first.representation.genericOwner(instance("Box", [TArray(firstValue), reference])) != null)
			throw "an array reference should not force the owner's value layout";
		var recursive = first.representation.genericOwner(instance("Recursive", [firstValue]));
		if (recursive == null) throw "recursive owner containing a value was not specialized";
		var beforeNested = first.representation.genericOwnerRequestCount();
		first.representation.discoverGenericOwners(instance("Recursive", [TArray(firstValue)]));
		if (first.representation.genericOwnerRequestCount() != beforeNested)
			throw "recursive reference containers caused unbounded owner specialization";
		var second = session(semantic, new GenericSpecializationRegistry(names.exportState()));
		var reloaded = second.representation.genericOwner(instance("Box", [firstValue, reference]));
		if (reloaded == null || reloaded.name != box.name || second.representation.genericOwnerRequestCount() != 1)
			throw "owner identity or discovery changed across typing sessions";
		second.representation.discoverGenericOwners(TFunction([TArray(instance("Nested", [firstValue, reference]))], TVoid));
		if (second.representation.genericOwnerRequestCount() != 2 || second.representation.genericOwnerRequest(1).origin != "Nested")
			throw "signature type discovery missed a nested generic owner";
		if (first.representation.genericOwner(instance("Box", [firstValue, TTypeParameter("fn", "T")])) != null)
			throw "an open generic owner was registered as a concrete layout";
		Sys.println("PASS: generic value owners have deterministic layout-aware identities");
	}

	static function instance(name:String, ?arguments:Array<CompilerType>):CompilerType
		return TInstance(Class, name, arguments == null ? [] : arguments);

	static function session(semantic:SemanticProgram, names:GenericSpecializationRegistry):TypingSession {
		var result = new TypingSession(null, names);
		result.bindSemantic(semantic);
		result.bindNominalDeclarations();
		return result;
	}
}
