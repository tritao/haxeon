package compiler.types.analysis;

import compiler.Source.SourceSpan;

/**
 * Which local maps of a function nothing else can reach, and where the analysis saw each of them used as a map operand.
 *
 * The second half is a check on the typer, not an input to it: the analysis resolved every use of a private map to
 * its declaration by its own scoping, and the typer resolves them again by its own. A use the typer meets that the
 * analysis did not classify means the two disagree, and a map treated as private then could be reachable after all.
 */
class MapPrivacy {
	public static final none = new MapPrivacy([], []);

	final privateDeclarations:Map<String, Bool>;
	final operandUses:Map<String, Bool>;

	public function new(privateDeclarations:Map<String, Bool>, operandUses:Map<String, Bool>) {
		this.privateDeclarations = privateDeclarations;
		this.operandUses = operandUses;
	}

	/** Whether the declaration `key` (see `BindingWalker.key`) is a map only this function can reach. */
	public function isPrivate(declaration:String):Bool
		return privateDeclarations.exists(declaration);

	/** Whether the analysis classified the use of `name` at `span` as a map operand. */
	public function isOperandUse(name:String, span:SourceSpan):Bool
		return operandUses.exists(BindingWalker.key(name, span));
}
