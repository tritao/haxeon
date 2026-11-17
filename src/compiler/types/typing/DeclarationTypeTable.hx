package compiler.types.typing;

import compiler.semantic.SemanticProgram;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFunction;
import compiler.types.DeclarationTypes;
import compiler.types.Type.CompilerType;
import haxe.ds.ObjectMap;

/**
 * The typer's answer to DeclarationTypes, owned by the TypingSession program view and given to DeclarationIndex by
 * TypingSession.bindSemantic. An unannotated declaration's entry will hold the type its initializer or body gives it, typed on
 * demand (docs/design/LAZY_DECLARATION_TYPING.md, slices 3 and 4); until then every declaration's type is the declared one.
 *
 * Each declaration has a stable key (`declarationKey`), the name the program's signature table gives it: `Owner.member` for a
 * field or method, the function's name for a module function. Entries and the reads recorded for invalidation use it, never an
 * AST node's identity, since a warm session replaces the AST of an edited module.
 */
class DeclarationTypeTable implements DeclarationTypes {
	final declared:DeclaredTypes;
	final keys = new ObjectMap<AstFunction, String>();

	/**
	 * The type of an unannotated argument's default value, which the body typer gives until slice 4 types it here; null in a
	 * session no body typer binds, where such an argument is Dynamic.
	 */
	final defaultValueType:Null<AstExpression->Null<CompilerType>>;

	public function new(declared:DeclaredTypes, semantic:SemanticProgram,
			defaultValueType:Null<AstExpression->Null<CompilerType>>) {
		this.declared = declared;
		this.defaultValueType = defaultValueType;
		for (name => fn in semantic.signatures)
			keys.set(fn, name);
		// The signature table holds an abstract's methods with the owner's type parameters added, and no enum methods.
		for (decl in semantic.program.abstracts)
			for (method in decl.methods)
				keys.set(method, decl.name + "." + method.name);
		for (decl in semantic.program.enums)
			if (decl.methods != null)
				for (method in decl.methods)
					keys.set(method, decl.name + "." + method.name);
	}

	/** The stable key of the declaration `fn` is, or null for a function no declaration holds (a closure, a specialization). */
	public function functionKey(fn:AstFunction):Null<String>
		return keys.get(fn);

	/** The stable key of `owner`'s field `field`. */
	public static function fieldKey(owner:String, field:AstField):String
		return owner + "." + field.name;

	public function fieldType(owner:String, field:AstField, ?substitutions:Map<String, CompilerType>):CompilerType
		return declared.fieldType(owner, field, substitutions);

	public function argumentTypes(fn:AstFunction, ?substitutions:Map<String, CompilerType>):Array<CompilerType>
		return [
			for (argument in fn.arguments)
				declared.argumentType(argument, substitutions,
				DeclaredTypes.typedByDefault(argument)
				&& defaultValueType != null ? defaultValueType(argument.defaultValue) : null)
		];

	public function resultType(fn:AstFunction, ?substitutions:Map<String, CompilerType>):CompilerType
		return declared.resultType(fn, substitutions);
}
