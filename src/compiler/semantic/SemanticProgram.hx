package compiler.semantic;

import compiler.core.InternalError;
import compiler.core.QualifiedName;
import compiler.semantic.DeclarationLifecycle.DeclarationStage;
import compiler.syntax.Ast.AstAbstract;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstInterface;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.AstFunctions;
import compiler.types.AccessorSignatures;
import compiler.types.DeclarationIndex;
import compiler.types.TypeRelations;

typedef SemanticLifecycleMetrics = {
	final declarationMs:Float;
	final shapeConnectionMs:Float;
	final signatureTypingMs:Float;
}

typedef DeclarationPositions = {
	final classes:Map<String, Int>;
	final abstracts:Map<String, Int>;
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

	/** `signatures` and `methodInfo` by owner, then member name (`QualifiedName.byOwner`). */
	public final signaturesByOwner:Map<String, Map<String, AstFunction>>;

	public final methodsByOwner:Map<String, Map<String, SemanticMethodInfo>>;
	public final lifecycle:DeclarationLifecycle;
	public final lifecycleMetrics:SemanticLifecycleMetrics;

	/**
	 * Where each module's `using` and each type's `@:using` find static extensions. The frontend sets it for each build from
	 * SemanticAssembly, which resolves it from the modules' syntax (a canonical program keeps no `using`); a program typed on its
	 * own has none.
	 */
	public var staticExtensions:StaticExtensionTable = StaticExtensionTable.empty();

	/**
	 * The canonical class each of `program.classes` was last refreshed from by `replaceBodies`, by position; null for one it has
	 * not refreshed (and past its end). A class whose canonical form has the same parts has nothing to refresh.
	 */
	var classSources:Array<Null<AstClass>>;

	var positions:Null<DeclarationPositions> = null;

	public static function analyze(program:AstProgram):SemanticProgram {
		return analyzeThrough(program, SignatureTyped);
	}

	/** Build a semantic snapshot only through the requested declaration stage. */
	public static function analyzeThrough(program:AstProgram, through:DeclarationStage):SemanticProgram {
		if ((through:Int) > (SignatureTyped:Int))
			throw new InternalError("Semantic analysis cannot type bodies or finalize without Typer");
		var started = Sys.time() * 1000.0;
		// An unannotated accessor of an annotated property has the property's type; what else a signature leaves out, its body gives.
		var inferred = AccessorSignatures.withPropertyTypes(InterfaceFieldAccessors.withAccessors(program));
		var declarations = DeclarationIndex.registered(inferred),
			declaredAt = Sys.time() * 1000.0,
			lifecycle = new DeclarationLifecycle(declarations),
			shapesAt = declaredAt,
			signaturesAt = declaredAt;
		if ((through:Int) >= (ShapeConnected:Int)) {
			declarations.connectShapes();
			lifecycle.advanceAll(ShapeConnected);
			shapesAt = Sys.time() * 1000.0;
			signaturesAt = shapesAt;
		}
		if ((through:Int) >= (SignatureTyped:Int)) {
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

	/**
	 * Reuses the validated declarations when only function bodies and field initializers changed. Only what changed is made again:
	 * the declarations whose canonical form `current` holds anew (a module whose canonical declarations were made again), and the
	 * selected functions, which take their current bodies. Everything else, the signature tables included, is shared with this
	 * program, which stays as it was.
	 */
	public function replaceBodies(current:AstProgram, selected:Map<String, Bool>):SemanticProgram {
		var functions = program.functions,
			classes = program.classes,
			abstracts = program.abstracts,
			changedSignatures:Array<{name:String, fn:AstFunction}> = [],
			nextClassSources = classSources,
			selectedClasses:Map<String, Bool> = [],
			selectedAbstracts:Map<String, Bool> = [],
			selectsFunctions = false;
		for (name in selected.keys()) {
			var info = methodInfo.get(name);
			if (info == null)
				selectsFunctions = true;
			else if (declarationPositions().classes.exists(info.owner))
				selectedClasses.set(info.owner, true);
			else if (declarationPositions().abstracts.exists(info.owner))
				selectedAbstracts.set(info.owner, true);
		}
		if (selectsFunctions) {
			var currentByName:Map<String, AstFunction> = [for (fn in current.functions) fn.name => fn];
			functions = [for (fn in program.functions) {
				var replacement = currentByName.get(fn.name);
				if (selected.exists(fn.name) && replacement != null) {
					var next = withBody(fn, replacement);
					changedSignatures.push({name: fn.name, fn: next});
					next;
				} else fn;
			}];
		}
		// The current classes are in the validated program's order (`SemanticAssembly`, `InterfaceFieldAccessors.withAccessors`); a
		// class not found at its position is looked up by name.
		var currentClasses:Null<Map<String, AstClass>> = null;
		function currentClass(index:Int, name:String):Null<AstClass> {
			var candidate = index < current.classes.length ? current.classes[index] : null;
			if (candidate != null && candidate.name == name)
				return candidate;
			if (currentClasses == null)
				currentClasses = [for (decl in current.classes) decl.name => decl];
			return currentClasses.get(name);
		}
		for (index in 0...program.classes.length) {
			var decl = program.classes[index],
				replacement = currentClass(index, decl.name);
			if (replacement == null
				|| (index < classSources.length && sameRefreshedParts(replacement, classSources[index])
				&& !selectedClasses.exists(decl.name)))
				continue;
			if (classes == program.classes) {
				classes = program.classes.copy();
				nextClassSources = [
					for (position in 0...program.classes.length)
						position < classSources.length ? classSources[position] : null
				];
			}
			var methods = withSelectedBodies(decl.name, decl.methods, replacement.methods, selected, changedSignatures,
				null);
			var next:Dynamic = copyWithMethods(decl, methods);
			// Keep validated field types while refreshing source-bearing initializer syntax.
			Reflect.setField(next, "span", replacement.span);
			Reflect.setField(next, "metadata", replacement.metadata);
			Reflect.setField(next, "fields", withInitializers(decl.fields, replacement.fields));
			classes[index] = cast next;
			nextClassSources[index] = replacement;
		}
		if (selectedAbstracts.keys().hasNext()) {
			var currentAbstracts = [for (decl in current.abstracts) decl.name => decl];
			abstracts = program.abstracts.copy();
			for (owner in selectedAbstracts.keys()) {
				var index = declarationPositions().abstracts.get(owner),
					decl = program.abstracts[index],
					replacement = currentAbstracts.get(owner);
				if (replacement != null)
					abstracts[index] = cast copyWithMethods(decl,
						withSelectedBodies(decl.name, decl.methods, replacement.methods, selected, changedSignatures,
						decl.typeParameters));
			}
		}
		var nextProgram:AstProgram = {
			packageName: program.packageName,
			imports: program.imports,
			usings: program.usings,
			aliases: program.aliases,
			enums: current.enums,
			abstracts: abstracts,
			interfaces: program.interfaces,
			classes: classes,
			functions: functions
		};
		var nextSignatures = signatures,
			nextSignaturesByOwner = signaturesByOwner;
		if (changedSignatures.length > 0) {
			nextSignatures = signatures.copy();
			nextSignaturesByOwner = signaturesByOwner.copy();
			var copiedOwners:Map<String, Bool> = [];
			for (changed in changedSignatures) {
				nextSignatures.set(changed.name, changed.fn);
				var separator = changed.name.lastIndexOf(".");
				if (separator < 0)
					continue;
				var owner = changed.name.substring(0, separator),
					members = nextSignaturesByOwner.get(owner);
				if (members == null)
					continue;
				if (!copiedOwners.exists(owner)) {
					members = members.copy();
					nextSignaturesByOwner.set(owner, members);
					copiedOwners.set(owner, true);
				}
				members.set(changed.name.substring(separator + 1), changed.fn);
			}
		}
		var next = new SemanticProgram(nextProgram, declarations, nextSignatures, methodInfo, relations,
			lifecycle.restarted(SignatureTyped), {
				declarationMs: 0.0,
				shapeConnectionMs: 0.0,
				signatureTypingMs: 0.0
			}, nextSignaturesByOwner, methodsByOwner);
		next.classSources = nextClassSources;
		next.positions = positions;
		return next;
	}

	/**
	 * Whether refreshing a class from `current` gives what refreshing it from `source` gave: the parts a refresh takes are the same
	 * objects. (A class given an implicit constructor is another object in every build, with the same parts.)
	 */
	static function sameRefreshedParts(current:AstClass, source:Null<AstClass>):Bool
		return source != null && current.span == source.span && current.metadata == source.metadata
			&& current.fields == source.fields;

	/**
	 * `methods` with the selected ones of `owner` given their bodies in `current`, each recorded in `changed` as the signature table
	 * holds it (with the owner's type parameters for an abstract's); `methods` itself when none is selected.
	 */
	static function withSelectedBodies(owner:String, methods:Array<AstFunction>, current:Array<AstFunction>,
			selected:Map<String, Bool>, changed:Array<{name:String, fn:AstFunction}>,
			ownerParameters:Null<Array<String>>):Array<AstFunction> {
		var result = methods, currentMethods:Null<Map<String, AstFunction>> = null;
		for (index in 0...methods.length) {
			var name = owner + "." + methods[index].name;
			if (!selected.exists(name))
				continue;
			if (currentMethods == null)
				currentMethods = [for (method in current) method.name => method];
			var currentMethod = currentMethods.get(methods[index].name);
			if (currentMethod == null)
				continue;
			if (result == methods)
				result = methods.copy();
			result[index] = withBody(methods[index], currentMethod);
			changed.push({
				name: name,
				fn: ownerParameters == null ? result[index] : withOwnerTypeParameters(result[index], ownerParameters)
			});
		}
		return result;
	}

	/** The position of each class and abstract in `program`, which the programs `replaceBodies` makes from this one share. */
	function declarationPositions():DeclarationPositions {
		var known = positions;
		if (known == null) {
			known = {
				classes: [for (index in 0...program.classes.length) program.classes[index].name => index],
				abstracts: [for (index in 0...program.abstracts.length) program.abstracts[index].name => index]
			};
			positions = known;
		}
		return known;
	}

	static function withInitializers(fields:Array<compiler.syntax.Ast.AstField>,
			current:Array<compiler.syntax.Ast.AstField>):Array<compiler.syntax.Ast.AstField> {
		var currentByName = [for (field in current) field.name => field];
		return [for (field in fields) {
			var replacement = currentByName.get(field.name);
			replacement == null ? field : {
				name: field.name,
				isPublic: field.isPublic,
				metadata: replacement.metadata,
				type: field.type,
				initializer: replacement.initializer,
				readAccess: field.readAccess,
				writeAccess: field.writeAccess,
				isStatic: field.isStatic,
				isInline: field.isInline,
				isFinal: field.isFinal,
				span: replacement.span
			};
		}];
	}

	static function copyWithMethods<T>(declaration:T, methods:Array<AstFunction>):T {
		var result:Dynamic = Reflect.copy(declaration);
		Reflect.setField(result, "methods", methods);
		return cast result;
	}

	static function withBody(signature:AstFunction, body:AstFunction):AstFunction {
		// Preserve validated declaration attributes (notably inline) when only source syntax changes.
		var arguments:Array<AstArgument> = [for (index in 0...signature.arguments.length) {
			var argument = signature.arguments[index], current = body.arguments[index];
			{
				name:argument.name,
					type:argument.type,
					optional:argument.optional,
					defaultValue:current.defaultValue,
					span:current.span
			};
		}];
		return AstFunctions.copy(signature, signature.name, signature.isStatic, body.metadata, signature.typeParameters,
			signature.typeConstraints, arguments,
			signature.result, body.statements, body.span);
	}

	function new(program:AstProgram, declarations:DeclarationIndex,
			?preparedSignatures:Map<String, AstFunction>,
			?preparedMethodInfo:Map<String, SemanticMethodInfo>, ?preparedRelations:TypeRelations,
			?preparedLifecycle:DeclarationLifecycle,
			?preparedLifecycleMetrics:SemanticLifecycleMetrics,
			?preparedSignaturesByOwner:Map<String, Map<String, AstFunction>>,
			?preparedMethodsByOwner:Map<String, Map<String, SemanticMethodInfo>>) {
		this.program = program;
		this.declarations = declarations;
		relations = preparedRelations == null ? new TypeRelations(declarations) : preparedRelations;
		lifecycle = preparedLifecycle == null ? new DeclarationLifecycle(declarations,
			SignatureTyped) : preparedLifecycle;
		lifecycleMetrics = preparedLifecycleMetrics == null ? {
			declarationMs: 0.0, shapeConnectionMs: 0.0, signatureTypingMs: 0.0
		} : preparedLifecycleMetrics;
		if (preparedSignatures != null && preparedMethodInfo != null) {
			signatures = preparedSignatures;
			methodInfo = preparedMethodInfo;
		} else {
			signatures = [];
			methodInfo = [];
			fillSignatures(program.interfaces, program.classes, program.abstracts, program.functions, signatures,
				methodInfo);
		}
		signaturesByOwner = preparedSignaturesByOwner == null
			? QualifiedName.byOwner(signatures) : preparedSignaturesByOwner;
		methodsByOwner = preparedMethodsByOwner == null ? QualifiedName.byOwner(methodInfo) : preparedMethodsByOwner;
		classSources = [];
	}

	/**
	 * The table of function signatures typing resolves calls against: interface, class and abstract methods under their
	 * qualified names, then the program's functions. Purity inference runs over it at typing time, and the drift check of
	 * `SemanticAssembly` must run over the same table to agree with what a cached body relied on.
	 */
	public static function signatureTable(program:AstProgram):Map<String, AstFunction> {
		var signatures:Map<String, AstFunction> = [];
		fillSignatures(program.interfaces, program.classes, program.abstracts, program.functions, signatures, null);
		return signatures;
	}

	public static function fillSignatures(interfaces:Array<AstInterface>, classes:Array<AstClass>,
			abstracts:Array<AstAbstract>, functions:Array<AstFunction>,
			signatures:Map<String, AstFunction>, methodInfo:Null<Map<String, SemanticMethodInfo>>):Void {
		for (decl in interfaces)
			for (method in decl.methods) {
				var name = decl.name + "." + method.name;
				signatures.set(name, method);
				if (methodInfo != null)
					methodInfo.set(name, {owner: decl.name, isStatic: false, isConstructor: false});
			}
		for (decl in classes)
			for (method in decl.methods) {
				var name = decl.name + "." + method.name;
				signatures.set(name, method);
				if (methodInfo != null)
					methodInfo.set(name, {
						owner: decl.name,
						isStatic: method.isStatic,
						isConstructor: method.name == "new"
					});
			}
		for (decl in abstracts)
			for (method in decl.methods) {
				var name = decl.name + "." + method.name,
					signature = withOwnerTypeParameters(method, decl.typeParameters);
				signatures.set(name, signature);
				if (methodInfo != null)
					methodInfo.set(name, {
						owner: decl.name,
						isStatic: method.isStatic,
						isConstructor: method.name == "new"
					});
			}
		for (fn in functions)
			signatures.set(fn.name, fn);
	}

	static function withOwnerTypeParameters(method:AstFunction, ownerParameters:Array<String>):AstFunction {
		var parameters = ownerParameters.copy(),
			methodParameters = method.typeParameters;
		if (methodParameters != null)
			for (parameter in methodParameters)
				parameters.push(parameter);
		return AstFunctions.withTypeParameters(method, parameters.length == 0 ? null : parameters);
	}
}
