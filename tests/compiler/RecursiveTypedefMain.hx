import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.ffi.NativeLayout;
import compiler.semantic.SemanticSignature;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.DeclarationIndex;
import compiler.types.Type.AnonymousField;
import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;
import compiler.types.typing.EqualityGenerator;

/**
 * A typedef may refer to itself through the fields of the anonymous structure it declares, as Haxe allows. The
 * resolved type then contains itself, so everything that walks it has to terminate. Every other cycle still cannot be
 * expanded and stays an error.
 */
class RecursiveTypedefMain {
	static function main():Void {
		var source = new SourceFile("Recursive.hx", "package demo;
typedef Tree = {name:String, children:Array<Tree>};
typedef Chain = {value:Int, next:Null<Chain>};
typedef Same = {name:String, children:Array<Same>};
typedef Different = {name:Int, children:Array<Different>};
typedef Left = {right:Null<Right>};
typedef Right = {left:Null<Left>};
typedef Wrap<T> = {item:T, more:Array<Wrap<T>>};
typedef Plain = {name:String, count:Int};
typedef Direct = Second;
typedef Second = Direct;
typedef Boxed = Array<Boxed>;
typedef Optional = Null<Optional>;
typedef Poly<T> = {next:Null<Poly<Array<T>>>};
class Marker {}
"),
			tokens = new Lexer(source).tokenize(),
			index = DeclarationIndex.registered(new Parser(tokens).parseProgram());

		function resolve(name:String):CompilerType
			return index.resolve(AstType.NamedType(name));

		// The resolved structure contains itself: the field that refers back to `Tree` is the same structure.
		var tree = resolve("Tree");
		var treeFields = fieldsOf(tree);
		expect(treeFields != null && treeFields.length == 2, "a recursive typedef resolves to its two fields");
		var children = field(treeFields, "children");
		expect(children != null, "the recursive field is present");
		switch children.type {
			case CompilerType.TArray(element):
				expect(fieldsOf(element) == treeFields, "the element type is the structure itself, sharing its field list");
				expect(nameOf(element) == nameOf(tree), "and carries the same name");
			default:
				expect(false, "children should be an array of the structure");
		}

		// A structure that contains itself is named after its typedef: spelling its fields would never end.
		expect(nameOf(tree) == SemanticSignature.recursiveAnonymousName("Tree"), 'unexpected name ${nameOf(tree)}');
		expect(SemanticSignature.isRecursiveAnonymousName(nameOf(tree)), "the name marks the structure as recursive");
		expect(SemanticSignature.type(tree) == nameOf(tree), "its signature is that name");

		// A typedef that does not refer to itself is spelled from its fields, exactly as before.
		var plain = resolve("Plain");
		expect(nameOf(plain) == "$anon:{count:Int,name:String}", 'a plain structure keeps its structural name, got ${nameOf(plain)}');
		expect(!SemanticSignature.isRecursiveAnonymousName(nameOf(plain)), "a plain structure is not recursive");

		// Resolving again gives the same structure.
		expect(fieldsOf(resolve("Tree")) == treeFields, "a resolved recursive typedef is reused");

		// Recursion through `Null<>` works the same way.
		var chain = resolve("Chain");
		var next = field(fieldsOf(chain), "next");
		switch next.type {
			case CompilerType.TNullable(inner):
				expect(fieldsOf(inner) == fieldsOf(chain), "a nullable back-reference is the structure itself");
			default:
				expect(false, "next should be nullable");
		}

		// Equality terminates and is structural: identical shapes are equal even when declared separately.
		expect(TypeRelations.equals(tree, tree), "a recursive type equals itself");
		expect(TypeRelations.equals(tree, resolve("Same")), "two typedefs with the same recursive shape are equal");
		expect(TypeRelations.equals(resolve("Same"), tree), "in both directions");
		expect(!TypeRelations.equals(tree, resolve("Different")), "a different field type makes recursive shapes differ");
		expect(!TypeRelations.equals(tree, chain), "different shapes differ");
		expect(!TypeRelations.equals(tree, plain), "a recursive and a plain structure differ");

		// Mutual recursion: each refers to the other, and both stay consistent.
		var left = resolve("Left"), right = resolve("Right");
		var leftToRight = field(fieldsOf(left), "right");
		switch leftToRight.type {
			case CompilerType.TNullable(rightType):
				var back = field(fieldsOf(rightType), "left");
				switch back.type {
					case CompilerType.TNullable(leftType): expect(TypeRelations.equals(leftType, left), "following the pair round returns to Left");
					default: expect(false, "Right.left should be nullable");
				}
				expect(TypeRelations.equals(rightType, right), "Left.right is Right");
			default:
				expect(false, "Left.right should be nullable");
		}

		// The order typedefs are resolved in makes no difference to the result.
		var reordered = DeclarationIndex.registered(new Parser(new Lexer(source).tokenize()).parseProgram());
		var rightFirst = reordered.resolve(AstType.NamedType("Right")),
			leftSecond = reordered.resolve(AstType.NamedType("Left"));
		expect(TypeRelations.equals(rightFirst, right)
			&& TypeRelations.equals(leftSecond, left), "resolving the pair in the other order gives equal types");
		expect(nameOf(rightFirst) == nameOf(right) && nameOf(leftSecond) == nameOf(left), "and the same names");

		// A generic typedef is recursive per instantiation, and instantiations stay apart.
		var wrapInt = index.resolve(AstType.AppliedType("Wrap", [AstType.IntType])),
			wrapFloat = index.resolve(AstType.AppliedType("Wrap", [AstType.FloatType]));
		expect(TypeRelations.equals(wrapInt, index.resolve(AstType.AppliedType("Wrap", [AstType.IntType]))), "Wrap<Int> equals itself");
		expect(!TypeRelations.equals(wrapInt, wrapFloat), "Wrap<Int> and Wrap<Float> differ");
		expect(nameOf(wrapInt) != nameOf(wrapFloat), "and are named apart");
		expect(field(fieldsOf(wrapInt), "item").type == CompilerType.TInt, "the type argument is substituted");

		// Everything that walks a structure must finish.
		expect(SemanticSignature.type(CompilerType.TArray(tree)).indexOf("Array<") == 0, "spelling a type that contains a recursive one finishes");
		expect(EqualityGenerator.equalsName(tree) == EqualityGenerator.equalsName(resolve("Tree")), "equality names are stable for a recursive type");
		expect(EqualityGenerator.equalsName(tree) != EqualityGenerator.equalsName(chain), "and differ between shapes");
		expect(!NativeLayout.containsNativeLayoutType(tree), "a recursive type holds no native layout");

		// Only cycles through an anonymous structure are allowed: anything else could never be expanded.
		for (name in ["Direct", "Second", "Boxed", "Optional"])
			expectError(function() resolve(name), 'the cyclic typedef "$name" must still be rejected');
		expectError(function() index.resolve(AstType.AppliedType("Poly", [AstType.IntType])),
			"a generic typedef that recurses at a different instantiation must still be rejected");
		expect(fieldsOf(resolve("Tree")) == treeFields, "rejected cycles leave resolved types alone");

		Sys.println("PASS: recursive typedefs");
	}

	static function fieldsOf(type:CompilerType):Null<Array<AnonymousField>>
		return switch type {
			case CompilerType.TAnonymous(_, fields): fields;
			default: null;
		};

	static function nameOf(type:CompilerType):String
		return switch type {
			case CompilerType.TAnonymous(name, _): name;
			default: "";
		};

	static function field(fields:Null<Array<AnonymousField>>, name:String):Null<AnonymousField> {
		if (fields != null)
			for (candidate in fields)
				if (candidate.name == name)
					return candidate;
		return null;
	}

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
