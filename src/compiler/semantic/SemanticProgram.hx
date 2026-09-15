package compiler.semantic;

import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstProgram;
import compiler.types.DeclarationIndex;
import compiler.types.SignatureInference;
import compiler.types.TypeRelations;
import compiler.semantic.DeclarationLifecycle.DeclarationStage;

typedef SemanticLifecycleMetrics = {
	final declarationMs:Float;
	final shapeConnectionMs:Float;
	final signatureTypingMs:Float;
}

typedef SemanticMethodInfo = {
	final owner:String;
	final isStatic:Bool;
	final isConstructor:Bool;
}

/** Validated global semantic facts for one canonical, assembled program. */
class SemanticProgram {
	public final program:AstProgram;
	public final declarations:DeclarationIndex;
	public final relations:TypeRelations;
	public final signatures:Map<String, AstFunction>;
	public final methodInfo:Map<String, SemanticMethodInfo>;
	public final lifecycle:DeclarationLifecycle;
	public final lifecycleMetrics:SemanticLifecycleMetrics;

	public static function analyze(program:AstProgram):SemanticProgram {
		return analyzeThrough(program, SignatureTyped);
	}

	/** Build editor declarations without allowing incomplete inheritance to abort body typing. */
	public static function analyzeRecovered(program:AstProgram, ?checkpoint:Void->Void):SemanticProgram {
		return analyzeThroughMode(program, SignatureTyped, true, checkpoint);
	}

	/** Build a semantic snapshot only through the requested declaration stage. */
	public static function analyzeThrough(program:AstProgram, through:DeclarationStage):SemanticProgram {
		return analyzeThroughMode(program, through, false);
	}

	static function analyzeThroughMode(program:AstProgram, through:DeclarationStage, recovered:Bool, ?checkpoint:Void->Void):SemanticProgram {
		if ((through : Int) > (SignatureTyped : Int))
			throw "Semantic analysis cannot type bodies or finalize without Typer";
		var started = Sys.time() * 1000.0;
		var inferred = SignatureInference.inferProgram(program, checkpoint);
		var declarations = recovered ? DeclarationIndex.registeredRecovered(inferred) : DeclarationIndex.registered(inferred),
			declaredAt = Sys.time() * 1000.0,
			lifecycle = new DeclarationLifecycle(declarations),
			shapesAt = declaredAt,
			signaturesAt = declaredAt;
		if ((through : Int) >= (ShapeConnected : Int)) {
			if (!recovered)
				declarations.connectShapes();
			lifecycle.advanceAll(ShapeConnected);
			shapesAt = Sys.time() * 1000.0;
			signaturesAt = shapesAt;
		}
		if ((through : Int) >= (SignatureTyped : Int)) {
			if (!recovered)
				declarations.validateProgramSignatures(inferred);
			lifecycle.advanceAll(SignatureTyped);
			signaturesAt = Sys.time() * 1000.0;
		}
		return new SemanticProgram(inferred, declarations, null, null, null, lifecycle, {
			declarationMs: declaredAt - started,
			shapeConnectionMs: shapesAt - declaredAt,
			signatureTypingMs: signaturesAt - shapesAt
		});
	}

	/** Reuse validated declarations when only explicitly typed top-level bodies changed. */
	public function replaceTopLevelBodies(current:AstProgram, selected:Map<String, Bool>):SemanticProgram {
		var currentByName:Map<String, AstFunction> = [];
		for (fn in current.functions)
			currentByName.set(fn.name, fn);
		var functions:Array<AstFunction> = [];
		for (fn in program.functions)
			if (selected.exists(fn.name) && currentByName.exists(fn.name))
				functions.push(withBody(fn, currentByName.get(fn.name)));
			else
				functions.push(fn);
		var nextProgram:AstProgram = {
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
		};
		var nextSignatures:Map<String, AstFunction> = [];
		for (name => fn in signatures)
			nextSignatures.set(name, fn);
		for (fn in functions)
			if (selected.exists(fn.name))
				nextSignatures.set(fn.name, fn);
		return new SemanticProgram(nextProgram, declarations, nextSignatures, methodInfo, relations, new DeclarationLifecycle(declarations, SignatureTyped),
			lifecycleMetrics);
	}

	/**
	 * Make another module's declarations available to tolerant typing without
	 * adding its symbols to the editor module's semantic index.
	 */
	public function includeRecoveredModule(program:AstProgram, external:DeclarationIndex, qualifiers:Array<String>):Void {
		for (name => declaration in external.aliases)
			if (!declarations.aliases.exists(name))
				declarations.aliases.set(name, declaration);
		for (name => declaration in external.enums)
			if (!declarations.enums.exists(name))
				declarations.enums.set(name, declaration);
		for (name => declaration in external.enumAbstracts)
			if (!declarations.enumAbstracts.exists(name))
				declarations.enumAbstracts.set(name, declaration);
		for (name => declaration in external.abstracts)
			if (!declarations.abstracts.exists(name))
				declarations.abstracts.set(name, declaration);
		for (name => declaration in external.interfaces)
			if (!declarations.interfaces.exists(name))
				declarations.interfaces.set(name, declaration);
		for (name => declaration in external.classes)
			if (!declarations.classes.exists(name))
				declarations.classes.set(name, declaration);

		for (fn in program.functions) {
			addRecoveredSignature(fn.name, fn, true);
			for (qualifier in qualifiers)
				addRecoveredSignature(qualifier + "." + fn.name, fn, true);
		}
		for (decl in program.interfaces) {
			for (method in decl.methods)
				addRecoveredMethod(decl.name, method, false, false, qualifiers);
		}
		for (decl in program.classes) {
			for (method in decl.methods)
				addRecoveredMethod(decl.name, method, method.isStatic, method.name == "new", qualifiers);
		}
		for (decl in program.abstracts) {
			for (method in decl.methods)
				addRecoveredMethod(decl.name, withOwnerTypeParameters(method, decl.typeParameters), method.isStatic, method.name == "new", qualifiers);
		}
	}

	function addRecoveredMethod(owner:String, method:AstFunction, isStatic:Bool, isConstructor:Bool, qualifiers:Array<String>):Void {
		var key = owner + "." + method.name;
		addRecoveredSignature(key, method, false, owner, isStatic, isConstructor);
		for (qualifier in qualifiers)
			addRecoveredSignature(qualifier + "." + key, method, false, owner, isStatic, isConstructor);
	}

	function addRecoveredSignature(key:String, method:AstFunction, topLevel:Bool, ?owner:String, ?isStatic:Bool, ?isConstructor:Bool):Void {
		if (signatures.exists(key))
			return;
		signatures.set(key, method);
		if (!topLevel)
			methodInfo.set(key, {
				owner: owner,
				isStatic: isStatic,
				isConstructor: isConstructor
			});
	}

	static function withBody(signature:AstFunction, body:AstFunction):AstFunction
		return {
			name: signature.name,
			isStatic: signature.isStatic,
			typeParameters: signature.typeParameters,
			typeConstraints: signature.typeConstraints,
			arguments: signature.arguments,
			result: signature.result,
			span: body.span,
			statements: body.statements
		};

	function new(program:AstProgram, declarations:DeclarationIndex, ?preparedSignatures:Map<String, AstFunction>,
			?preparedMethodInfo:Map<String, SemanticMethodInfo>, ?preparedRelations:TypeRelations, ?preparedLifecycle:DeclarationLifecycle,
			?preparedLifecycleMetrics:SemanticLifecycleMetrics) {
		this.program = program;
		this.declarations = declarations;
		relations = preparedRelations == null ? new TypeRelations(declarations) : preparedRelations;
		lifecycle = preparedLifecycle == null ? new DeclarationLifecycle(declarations, SignatureTyped) : preparedLifecycle;
		lifecycleMetrics = preparedLifecycleMetrics == null ? {declarationMs: 0.0, shapeConnectionMs: 0.0, signatureTypingMs: 0.0} : preparedLifecycleMetrics;
		if (preparedSignatures != null && preparedMethodInfo != null) {
			signatures = preparedSignatures;
			methodInfo = preparedMethodInfo;
			return;
		}
		signatures = [];
		methodInfo = [];
		for (decl in program.interfaces)
			for (method in decl.methods) {
				var name = decl.name + "." + method.name;
				signatures.set(name, method);
				methodInfo.set(name, {owner: decl.name, isStatic: false, isConstructor: false});
			}
		for (decl in program.classes)
			for (method in decl.methods) {
				var name = decl.name + "." + method.name;
				signatures.set(name, method);
				methodInfo.set(name, {owner: decl.name, isStatic: method.isStatic, isConstructor: method.name == "new"});
			}
		for (decl in program.abstracts)
			for (method in decl.methods) {
				var name = decl.name + "." + method.name,
					signature = withOwnerTypeParameters(method, decl.typeParameters);
				signatures.set(name, signature);
				methodInfo.set(name, {owner: decl.name, isStatic: method.isStatic, isConstructor: method.name == "new"});
			}
		for (fn in program.functions)
			signatures.set(fn.name, fn);
	}

	static function withOwnerTypeParameters(method:AstFunction, ownerParameters:Array<String>):AstFunction {
		var parameters = ownerParameters.copy(),
			methodParameters = method.typeParameters;
		if (methodParameters != null)
			for (parameter in methodParameters)
				parameters.push(parameter);
		return {
			name: method.name,
			isStatic: method.isStatic,
			typeParameters: parameters.length == 0 ? null : parameters,
			typeConstraints: method.typeConstraints,
			arguments: method.arguments,
			result: method.result,
			span: method.span,
			statements: method.statements
		};
	}
}
