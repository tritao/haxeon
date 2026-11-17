package compiler.types.typing;

import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFunction;
import compiler.types.DeclarationTypes;
import compiler.types.Type.CompilerType;

/**
 * The typer's answer to DeclarationTypes, owned by the TypingSession program view and given to DeclarationIndex by
 * TypingSession.bindSemantic. An unannotated declaration's entry will hold the type its initializer or body gives it, typed on
 * demand (docs/design/LAZY_DECLARATION_TYPING.md, slices 3 and 4); until then every declaration's type is the declared one.
 */
class DeclarationTypeTable implements DeclarationTypes {
	final declared:DeclaredTypes;

	public function new(declared:DeclaredTypes)
		this.declared = declared;

	public function fieldType(owner:String, field:AstField, ?substitutions:Map<String, CompilerType>):CompilerType
		return declared.fieldType(owner, field, substitutions);

	public function signature(fn:AstFunction, ?substitutions:Map<String, CompilerType>):ResolvedSignature
		return declared.signature(fn, substitutions);
}
