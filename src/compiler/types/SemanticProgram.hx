package compiler.types;

import compiler.Ast.AstFunction;
import compiler.Ast.AstProgram;

/** Validated global semantic facts for one canonical, assembled program. */
class SemanticProgram {
	public final program:AstProgram;
	public final declarations:DeclarationIndex;

	public static function analyze(program:AstProgram):SemanticProgram {
		var inferred = SignatureInference.inferProgram(program);
		return new SemanticProgram(inferred, DeclarationIndex.validated(inferred));
	}

	/** Reuse validated declarations when only explicitly typed top-level bodies changed. */
	public function replaceTopLevelBodies(current:AstProgram, selected:Map<String, Bool>):SemanticProgram {
		var currentByName:Map<String, AstFunction> = [];
		for (fn in current.functions)
			currentByName.set(fn.name, fn);
		var functions = [
			for (fn in program.functions)
				if (selected.exists(fn.name) && currentByName.exists(fn.name)) withBody(fn, currentByName.get(fn.name)) else fn
		];
		return new SemanticProgram({
			packageName: program.packageName,
			imports: program.imports,
			importAliases: program.importAliases,
			aliases: program.aliases,
			enums: program.enums,
			enumAbstracts: program.enumAbstracts,
			abstracts: program.abstracts,
			interfaces: program.interfaces,
			classes: program.classes,
			functions: functions
		}, declarations);
	}

	static function withBody(signature:AstFunction, body:AstFunction):AstFunction
		return {
			name: signature.name,
			isStatic: signature.isStatic,
			typeParameters: signature.typeParameters,
			arguments: signature.arguments,
			result: signature.result,
			span: body.span,
			statements: body.statements
		};

	function new(program:AstProgram, declarations:DeclarationIndex) {
		this.program = program;
		this.declarations = declarations;
	}
}
