package compiler.semantic;

import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.modules.ModulePath;
import compiler.syntax.Token;
import compiler.syntax.Token.TokenKind;
import compiler.syntax.AstChildren;
import compiler.types.DeclarationIndex;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstEnumParameter;
import compiler.service.CancellationToken;
import compiler.modules.ModuleState.SemanticDependencyKind;

abstract SemanticSymbolId(String) from String to String {
	public inline function new(module:String, declaration:String)
		this = module + ":" + declaration;
}

typedef IndexedSemanticSymbol = {
	final id:SemanticSymbolId;
	final name:String;
	final kind:DeclarationKind;
	final declaration:SourceSpan;
}

private typedef PositionBinding = {final span:SourceSpan; final symbol:SemanticSymbolId;}

typedef SemanticRecoveredTypeParameterScope = {
	final name:String;
	final owner:String;
	final span:SourceSpan;
}

private typedef RecoveredEnumPattern = {
	final params:Array<AstEnumParameter>;
	final substitutions:Map<String, CompilerType>;
}

typedef SemanticCompletionLocal = {
	final name:String;
	final type:CompilerType;
	final declaration:SourceSpan;
	final scope:SourceSpan;
	final depth:Int;
}

enum SemanticCompletionContextKind {
	Expression;
	Member;
	Type;
	Argument;
	Import;
	ObjectField;
	Override;
	Pattern;
}

typedef SemanticCompletionContext = {
	final locals:Array<SemanticCompletionLocal>;
	final typeParameters:Array<String>;
	final receiver:Null<CompilerType>;
	final expected:Null<CompilerType>;
	final kind:SemanticCompletionContextKind;
}

typedef UnresolvedSymbol = {
	final name:String;
	final span:SourceSpan;
	final candidates:Array<SemanticSymbolId>;
}

typedef SemanticSignatureInfo = {
	final label:String;
	final parameters:Array<String>;
	final result:String;
}

typedef SemanticCallEdge = {
	final caller:SemanticSymbolId;
	final callee:SemanticSymbolId;
	final span:SourceSpan;
}

/** Dependency on a declaration established from a successfully typed node. */
typedef ResolvedSemanticReference = {
	final owner:String;
	final target:String;
	final targetId:SemanticSymbolId;
	final kind:SemanticDependencyKind;
}

/** Mutable construction state for one revision-local semantic index. */
@:allow(compiler.semantic.SemanticIndex)
@:allow(compiler.semantic.SemanticIndexQueryState)
class SemanticIndexBuilder {
	public final revision:Int;
	final symbols:Map<String, IndexedSemanticSymbol> = [];
	public var indexingMs(default, null):Float = 0.0;
	public var isFrozen(get, never):Bool;

	final bindings:Array<PositionBinding> = [];
	final symbolIdsByName:Map<String, Array<SemanticSymbolId>> = [];
	final references:Map<String, Array<SourceSpan>> = [];
	final referenceKeys:Map<String, Map<String, Bool>> = [];
	final signatures:Map<String, SemanticSignatureInfo> = [];
	final callEdges:Array<SemanticCallEdge> = [];
	final resolvedReferences:Array<ResolvedSemanticReference> = [];
	final completionLocals:Array<SemanticCompletionLocal> = [];
	final functionReceivers:Array<{span:SourceSpan, type:CompilerType}> = [];
	final completionTypes:Array<{span:SourceSpan, type:CompilerType}> = [];
	final declarationTypes:Map<SemanticSymbolId, CompilerType> = [];
	final declarationSymbolsBySpan:Map<String, SemanticSymbolId> = [];
	final recoveredMembers:Map<String, SemanticSymbolId> = [];
	final knownRecoveredMembers:Map<String, Bool> = [];
	final recoveredFunctions:Map<String, AstFunction> = [];
	final recoveredClassBases:Map<String, CompilerType> = [];
	final recoveredLocalNext:Map<String, Int> = [];
	final unresolved:Array<UnresolvedSymbol> = [];
	final recoveredTypeParameterScopes:Array<SemanticRecoveredTypeParameterScope> = [];
	final typeParameterIds:Map<String, SemanticSymbolId> = [];
	final declarations:DeclarationIndex;
	final tokens:Array<Token>;
	final module:String;
	/** Source owned by the snapshot being indexed, used to rebind cached spans. */
	final source:Null<SourceFile>;
	var cancellation:Null<CancellationToken>;
	var currentRecoveredTypeParameters:Map<String, CompilerType> = [];
	/** Function key used to keep recovered lambda locals distinct and stable. */
	var currentRecoveredFunctionKey:String = "";
	var recoveryResolve:Null<String->Null<SemanticSymbolId>>;
	var recoveryCandidates:Null<String->Array<SemanticSymbolId>>;
	var recoveryResolveEnumCase:Null<(String, Int) -> Null<SemanticSymbolId>>;
	var recoveryResolveType:Null<(String, Array<CompilerType>) -> Null<CompilerType>>;
	var recoveryPreviousLocalIds:Map<String, Array<SemanticSymbolId>> = [];
	var recoveryPreviousLocalSpans:Map<String, SourceSpan> = [];
	var recoveryUsedLocalIds:Map<String, Bool> = [];
	var recoveryPreviousLambdaKeys:Map<String, Array<String>> = [];
	var recoveryCurrentLambdaOrdinals:Map<String, Int> = [];
	var currentCaller:Null<SemanticSymbolId>;
	var currentCallerName:Null<String>;
	var currentDependencyKind:SemanticDependencyKind = SemanticDependencyKind.Body;
	var checkpointCount:Int = 0;
	var frozen:Bool = false;
	var frozenIndex:Null<SemanticIndex>;

	public function new(path:String, revision:Int, declarations:DeclarationIndex, tokens:Array<Token>, ?initialize:Bool = true) {
		module = ModulePath.fromFile(path);
		this.revision = revision;
		this.declarations = declarations;
		this.tokens = tokens;
		this.source = tokens.length == 0 ? null : tokens[0].span.file;
		if (!initialize)
			return;
		var keys = [for (key in declarations.symbols.keys()) key];
		keys.sort(Reflect.compare);
		for (key in keys) {
			if (!declarations.symbols.exists(key))
				throw 'Missing semantic declaration "$key"';
			var declaration = declarations.symbols.get(key);
			if (declaration.name == "<missing>")
				continue;
			var id = new SemanticSymbolId(module, declaration.id),
				binding = declarationToken(tokens, declaration.span, sourceName(declaration.name));
			symbols.set(id, {
				id: id,
				name: declaration.name,
				kind: declaration.kind,
				declaration: declaration.span
			});
			addSymbolName(declaration.name, id);
			declarationSymbolsBySpan.set(spanKey(declaration.span), id);
			if (binding != null)
				bind(id, binding.span);
		}
		for (enumDecl in declarations.enums)
			for (enumCase in enumDecl.cases) {
				var parameters = [
					for (index in 0...enumCase.params.length) {
						var parameter = enumCase.params[index];
						(parameter.name == null ? "arg" + index : parameter.name) + ":" + displayAstType(parameter.type);
					}
				];
				setDeclaredSignature(enumDecl.name + "." + enumCase.name, enumDecl.name + "." + enumCase.name + "(" + parameters.join(", ") + ")", parameters,
					enumDecl.name);
			}
		for (classDecl in declarations.classes)
			for (method in classDecl.methods)
				if (method.name == "new") {
					var parameters = [
						for (argument in method.arguments)
							argument.name + ":" + displayAstType(argument.type)
					];
					setDeclaredSignature(classDecl.name, classDecl.name + "(" + parameters.join(", ") + ")", parameters, classDecl.name);
				}
		for (fn in declarations.classes)
			indexDeclarationTypes(fn.name, fn.fields, fn.methods, declarations);
		for (fn in declarations.interfaces)
			indexDeclarationTypes(fn.name, [], fn.methods, declarations);
		for (fn in declarations.abstracts)
			indexDeclarationTypes(fn.name, [], fn.methods, declarations);
	}

	/** Publish a query-only view after all indexing work has completed. */
	public function freeze():SemanticIndex {
		if (frozenIndex != null)
			return frozenIndex;
		completeCallEdges();
		var published = frozenCopy();
		frozen = true;
		frozenIndex = new SemanticIndex(published, SemanticIndexQueryState.fromBuilder(published));
		return frozenIndex;
	}

	/** Create a view for construction-time compatibility and diagnostics. */
	public function view():SemanticIndex
		return new SemanticIndex(this);

	/** Return a read-only-by-convention copy for the query facade. */
	public function snapshotSymbols():Map<String, IndexedSemanticSymbol>
		return symbols.copy();

	/**
		Detach the query state before publication. The builder remains available
		to construction callers for diagnostics, but the published facade no
		longer shares its mutable maps and arrays.
	*/
	function frozenCopy():SemanticIndexBuilder {
		var copy = new SemanticIndexBuilder(module, revision, declarations, tokens.copy(), false);
		copy.indexingMs = indexingMs;
		for (id => symbol in symbols)
			copy.symbols.set(id, symbol);
		for (binding in bindings)
			copy.bindings.push({span: binding.span, symbol: binding.symbol});
		for (name => ids in symbolIdsByName)
			copy.symbolIdsByName.set(name, ids.copy());
		for (id => spans in references)
			copy.references.set(id, spans.copy());
		for (id => keys in referenceKeys) {
			var copiedKeys:Map<String, Bool> = [];
			for (key => value in keys)
				copiedKeys.set(key, value);
			copy.referenceKeys.set(id, copiedKeys);
		}
		for (id => signature in signatures)
			copy.signatures.set(id, {
				label: signature.label,
				parameters: signature.parameters.copy(),
				result: signature.result
			});
		for (edge in callEdges)
			copy.callEdges.push({caller: edge.caller, callee: edge.callee, span: edge.span});
		for (reference in resolvedReferences)
			copy.resolvedReferences.push({
				owner: reference.owner,
				target: reference.target,
				targetId: reference.targetId,
				kind: reference.kind
			});
		for (local in completionLocals)
			copy.completionLocals.push({
				name: local.name,
				type: local.type,
				declaration: local.declaration,
				scope: local.scope,
				depth: local.depth
			});
		for (receiver in functionReceivers)
			copy.functionReceivers.push({span: receiver.span, type: receiver.type});
		for (completion in completionTypes)
			copy.completionTypes.push({span: completion.span, type: completion.type});
		for (id => type in declarationTypes)
			copy.declarationTypes.set(id, type);
		for (span => id in declarationSymbolsBySpan)
			copy.declarationSymbolsBySpan.set(span, id);
		for (name => id in recoveredMembers)
			copy.recoveredMembers.set(name, id);
		for (name => value in knownRecoveredMembers)
			copy.knownRecoveredMembers.set(name, value);
		for (name => fn in recoveredFunctions)
			copy.recoveredFunctions.set(name, fn);
		for (name => type in recoveredClassBases)
			copy.recoveredClassBases.set(name, type);
		for (name => next in recoveredLocalNext)
			copy.recoveredLocalNext.set(name, next);
		for (symbol in unresolved)
			copy.unresolved.push({name: symbol.name, span: symbol.span, candidates: symbol.candidates.copy()});
		for (scope in recoveredTypeParameterScopes)
			copy.recoveredTypeParameterScopes.push({name: scope.name, owner: scope.owner, span: scope.span});
		for (key => id in typeParameterIds)
			copy.typeParameterIds.set(key, id);
		for (name => type in currentRecoveredTypeParameters)
			copy.currentRecoveredTypeParameters.set(name, type);
		copy.currentRecoveredFunctionKey = currentRecoveredFunctionKey;
		copy.currentDependencyKind = currentDependencyKind;
		copy.checkpointCount = checkpointCount;
		copy.frozen = true;
		return copy;
	}

	inline function ensureMutable():Void {
		if (frozen)
			throw "Semantic index builder was used after publication";
	}

	function indexDeclarationTypes(owner:String, fields:Array<compiler.syntax.Ast.AstField>, methods:Array<compiler.syntax.Ast.AstFunction>,
			declarations:DeclarationIndex):Void {
		for (field in fields)
			if (field.type != null)
				try {
					var resolved = declarations.resolve(field.type, field.span);
					// A module-local declaration index intentionally does not own
					// imported types. Keep that unresolved result out of the type
					// table so later semantic indexing can supply the authoritative
					// cross-module identity instead of pinning TUnknown.
					if (resolved != TUnknown && resolved != TError)
						setDeclarationType(owner + "." + field.name, field.span, resolved);
				}
				catch (_:Dynamic) {}
		for (method in methods)
			try {
				var resolved = declarations.resolve(method.result, method.span);
				if (resolved != TUnknown && resolved != TError)
					setDeclarationType(owner + "." + method.name, method.span, resolved);
			}
			catch (_:Dynamic) {}
	}

	function setDeclarationType(name:String, span:SourceSpan, type:CompilerType):Void {
		var id = declarationSymbolsBySpan.get(spanKey(span));
		if (id != null) {
			declarationTypes.set(id, type);
			return;
		}
		for (symbol in symbols)
			if (symbol.name == name)
				declarationTypes.set(symbol.id, type);
	}

	static inline function spanKey(span:SourceSpan):String
		return span.start + ":" + span.end;

	function setDeclaredSignature(symbolName:String, label:String, parameters:Array<String>, result:String):Void {
		var ids = symbolIdsByName.get(symbolName);
		if (ids != null)
			for (id in ids) {
				if (Std.string(id).indexOf(":local:") >= 0)
					continue;
				signatures.set(id, {label: label, parameters: parameters, result: result});
			}
	}

	function addSymbolName(name:String, id:SemanticSymbolId):Void {
		var ids = symbolIdsByName.get(name);
		if (ids == null) {
			ids = [];
			symbolIdsByName.set(name, ids);
		}
		ids.push(id);
	}

	function get_isFrozen():Bool
		return frozen;

	/** Complete call edges before the builder is detached for publication. */
	function completeCallEdges():Void {
		ensureMutable();
		for (caller in symbols) {
			if (caller.kind != DeclarationKind.Function && caller.kind != DeclarationKind.Member)
				continue;
			var declarationLocations = references.get(caller.id),
				declarationStart = declarationLocations == null || declarationLocations.length == 0 ? -1 : declarationLocations[0].start;
			for (index in 0...tokens.length) {
				var token = tokens[index];
				if (token.span.start < caller.declaration.start
					|| token.span.end > caller.declaration.end
					|| token.kind != TokenKind.Identifier
					|| index + 1 >= tokens.length
					|| tokens[index + 1].kind != TokenKind.LeftParen
					|| token.span.start == declarationStart)
					continue;
				var callee = symbolIdAtForConstruction(token.span.start);
				if (callee == null)
					continue;
				var duplicate = false;
				for (edge in callEdges)
					if (edge.caller == caller.id && edge.callee == callee && edge.span.start == token.span.start) {
						duplicate = true;
						break;
					}
				if (!duplicate)
					callEdges.push({caller: caller.id, callee: callee, span: token.span});
			}
		}
	}

	public function indexTypedFunction(fn:TypedFunction, resolve:String->Null<SemanticSymbolId>, resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>,
			?token:CancellationToken, ?deferBindingSort = false):Void {
		ensureMutable();
		var started = Sys.time();
		if (token != null)
			token.check();
		cancellation = token;
		checkpoint();
		for (argument in fn.arguments) {
			declareLocal(fn, argument.name, fn.span, argument.type);
			addCompletionLocal(argument.name, argument.type, fn.span, fn.span, 0);
		}
		if (fn.owner != null && !fn.isStatic && !hasFunctionReceiver(fn.span))
			functionReceivers.push({span: currentSpan(fn.span), type: typedReceiverType(fn.owner, fn.span)});
		var functionId = resolve(fn.name);
		if (functionId != null) {
			declarationTypes.set(functionId, fn.result);
			var parameters = [
				for (argument in fn.arguments)
					sourceLocalName(argument.name) + ":" + displayType(argument.type)
			], name = sourceName(fn.name);
			signatures.set(functionId, {
				label: name + "(" + parameters.join(", ") + "):" + displayType(fn.result),
				parameters: parameters,
				result: displayType(fn.result)
			});
		}
		declareLocals(fn, fn.statements);
		indexCompletionLocals(fn.statements, fn.span, 0);
		currentCaller = functionId;
		currentCallerName = fn.name;
		indexStatements(fn, fn.statements, resolve, resolveEnumCase);
		indexCallTokens(fn, functionId, resolve);
		currentCaller = null;
		currentCallerName = null;
		if (!deferBindingSort)
			bindings.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
		checkpoint();
		cancellation = null;
		indexingMs += (Sys.time() - started) * 1000.0;
	}

	/** Index source-level generic parameters as editor-local semantic declarations. */
	public function indexTypeParameterDeclarations(program:AstProgram):Void {
		ensureMutable();
		for (alias in program.aliases)
			indexTypeParameters(alias.name, alias.span, alias.typeParameters);
		for (decl in program.enums)
			indexTypeParameters(decl.name, decl.span, decl.typeParameters);
		for (decl in program.abstracts)
			indexTypeParameters(decl.name, decl.span, decl.typeParameters);
		for (decl in program.interfaces)
			indexTypeParameters(decl.name, decl.span, decl.typeParameters);
		for (decl in program.classes) {
			indexTypeParameters(decl.name, decl.span, decl.typeParameters);
			for (method in decl.methods)
				indexTypeParameters(decl.name + "." + method.name, method.span, method.typeParameters);
		}
		for (decl in program.interfaces)
			for (method in decl.methods)
				indexTypeParameters(decl.name + "." + method.name, method.span, method.typeParameters);
		for (decl in program.abstracts)
			for (method in decl.methods)
				indexTypeParameters(decl.name + "." + method.name, method.span, method.typeParameters);
		for (fn in program.functions)
			indexTypeParameters(fn.name, fn.span, fn.typeParameters);
	}

	function indexTypeParameters(owner:String, declaration:SourceSpan, parameters:Null<Array<String>>):Void {
		if (parameters == null || parameters.length == 0)
			return;
		var spans = typeParameterTokenSpans(owner, declaration, parameters);
		for (name in parameters) {
			var tokenSpan = spans.get(name);
			if (tokenSpan == null)
				continue;
			var key = typeParameterKey(owner, name), id = typeParameterIds.get(key);
			if (id == null) {
				id = new SemanticSymbolId(module, "type-parameter:" + owner + ":" + name);
				typeParameterIds.set(key, id);
			}
			if (!symbols.exists(id)) {
				symbols.set(id, {
					id: id,
					name: name,
					kind: DeclarationKind.TypeParameter,
					declaration: tokenSpan
				});
				addSymbolName(name, id);
				declarationSymbolsBySpan.set(spanKey(tokenSpan), id);
			}
			rememberRecoveredTypeParameter(name, declaration, owner);
			bind(id, tokenSpan);
		}
	}

	/** Find only the parameter identifiers at generic-list depth one. */
	function typeParameterTokenSpans(owner:String, declaration:SourceSpan, parameters:Null<Array<String>>):Map<String, SourceSpan> {
		var result:Map<String, SourceSpan> = [],
			anchor = sourceName(owner),
			index = firstTokenAtOrAfter(declaration.start),
			anchorFound = false,
			depth = 0,
			expecting = false;
		while (index < tokens.length) {
			var token = tokens[index++];
			if (token.span.start >= declaration.end)
				break;
			if (!anchorFound) {
				if (token.kind == TokenKind.Identifier && token.text == anchor)
					anchorFound = true;
				continue;
			}
			if (depth == 0) {
				if (token.kind != TokenKind.Less)
					continue;
				depth = 1;
				expecting = true;
				continue;
			}
			switch token.kind {
				case Less:
					depth++;
				case Greater:
					depth--;
					expecting = false;
				case Comma:
					if (depth == 1)
						expecting = true;
				case Identifier:
					if (depth == 1 && expecting && parameters.indexOf(token.text) >= 0) {
						result.set(token.text, token.span);
						expecting = false;
					}
				default:
			}
			if (depth == 0)
				break;
		}
		return result;
	}

	/** Index usable local facts from a recovered syntax tree without requiring successful typing. */
	public function indexRecoveredSyntax(program:AstProgram, ?token:CancellationToken, ?typedProgram:TypedProgram, ?resolve:String->Null<SemanticSymbolId>,
			?resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>, ?resolveType:(String, Array<CompilerType>) -> Null<CompilerType>,
			?candidates:String->Array<SemanticSymbolId>, ?previous:SemanticIndexBuilder):Void {
		ensureMutable();
		cancellation = token;
		recoveryResolve = resolve;
		recoveryCandidates = candidates;
		recoveryResolveEnumCase = resolveEnumCase;
		recoveryResolveType = resolveType;
		prepareRecoveredLocalReuse(previous);
		if (token != null)
			token.check();
		indexRecoveredProgramTypes(program);
		for (fn in program.functions) {
			checkpoint();
			recoveredFunctions.set(fn.name, fn);
		}
		for (owner in program.classes) {
			checkpoint();
			rememberRecoveredTypeParameters(owner.typeParameters, owner.span, owner.name);
			if (owner.base != null)
				recoveredClassBases.set(owner.name, recoveredType(owner.base));
			for (fn in owner.methods)
				recoveredFunctions.set(owner.name + "." + fn.name, fn);
		}
		for (owner in program.interfaces) {
			checkpoint();
			rememberRecoveredTypeParameters(owner.typeParameters, owner.span, owner.name);
			for (fn in owner.methods)
				recoveredFunctions.set(owner.name + "." + fn.name, fn);
		}
		for (owner in program.abstracts) {
			checkpoint();
			rememberRecoveredTypeParameters(owner.typeParameters, owner.span, owner.name);
			for (fn in owner.methods)
				recoveredFunctions.set(owner.name + "." + fn.name, fn);
		}
		for (fn in program.functions)
			rememberRecoveredTypeParameters(fn.typeParameters, fn.span, fn.name);
		for (owner in program.classes) {
			checkpoint();
			for (field in owner.fields)
				rememberRecoveredMember(owner.name, field.name, field.span);
			for (method in owner.methods)
				rememberRecoveredMember(owner.name, method.name, method.span);
		}
		for (owner in program.interfaces) {
			checkpoint();
			for (method in owner.methods)
				rememberRecoveredMember(owner.name, method.name, method.span);
		}
		for (owner in program.abstracts) {
			checkpoint();
			for (method in owner.methods)
				rememberRecoveredMember(owner.name, method.name, method.span);
		}
		for (fn in program.functions) {
			checkpoint();
			indexRecoveredFunction(fn, null);
		}
		for (owner in program.classes) {
			checkpoint();
			for (fn in owner.methods)
				indexRecoveredFunction(fn, owner.name, owner.typeParameters);
		}
		for (owner in program.interfaces) {
			checkpoint();
			for (fn in owner.methods)
				indexRecoveredFunction(fn, owner.name, owner.typeParameters);
		}
		for (owner in program.abstracts) {
			checkpoint();
			for (fn in owner.methods)
				indexRecoveredFunction(fn, owner.name, owner.typeParameters);
		}
		if (typedProgram != null)
			for (fn in typedProgram.functions) {
				checkpoint();
				// Generated lambda bodies were already indexed from the recovered AST
				// above. Indexing the typed copy as well would recreate its locals from
				// the current source offset and shadow the stable recovery identity.
				if (StringTools.startsWith(fn.name, "$lambda:"))
					continue;
				indexTypedFunction(fn, resolveRecoveredSymbol, resolveRecoveredEnumCase, token, true);
				cancellation = token;
			}
		// Bind type annotations from the current recovered source as well as
		// expression uses. Resolved names retain authoritative identities when
		// available, while declarations from this module remain editor-local.
		indexTypeReferences(function(name:String):Null<SemanticSymbolId> return resolvedRecoveredSymbol(name), token);
		cancellation = token;
		bindings.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
		checkpoint();
		cancellation = null;
		recoveryResolve = null;
		recoveryCandidates = null;
		recoveryResolveEnumCase = null;
		recoveryResolveType = null;
		recoveryPreviousLocalIds = [];
		recoveryPreviousLocalSpans = [];
		recoveryUsedLocalIds = [];
		recoveryPreviousLambdaKeys = [];
		recoveryCurrentLambdaOrdinals = [];
	}

	/**
	 * Visit every declaration-level source type before indexing expressions.
	 * AstType does not currently carry token spans, so the final identifier
	 * binding is still performed by indexTypeReferences(). This pass keeps
	 * recovery resolution and type traversal in lockstep with the source AST,
	 * including type positions which do not occur in an expression walker.
	 */
	function indexRecoveredProgramTypes(program:AstProgram):Void {
		for (alias in program.aliases) {
			indexRecoveredTypeSyntax(alias.type);
			indexRecoveredTypeConstraints(alias.typeConstraints);
		}
		for (decl in program.enums) {
			indexRecoveredTypeConstraints(decl.typeConstraints);
			for (caseDecl in decl.cases)
				for (parameter in caseDecl.params)
					indexRecoveredTypeSyntax(parameter.type);
		}
		for (decl in program.enumAbstracts) {
			indexRecoveredTypeSyntax(decl.underlying);
			for (type in decl.fromTypes)
				indexRecoveredTypeSyntax(type);
			for (type in decl.toTypes)
				indexRecoveredTypeSyntax(type);
		}
		for (decl in program.abstracts) {
			indexRecoveredTypeConstraints(decl.typeConstraints);
			indexRecoveredTypeSyntax(decl.underlying);
			for (type in decl.fromTypes)
				indexRecoveredTypeSyntax(type);
			for (type in decl.toTypes)
				indexRecoveredTypeSyntax(type);
		}
		for (decl in program.interfaces) {
			indexRecoveredTypeConstraints(decl.typeConstraints);
			for (base in decl.bases)
				indexRecoveredTypeSyntax(base);
		}
		for (decl in program.classes) {
			indexRecoveredTypeConstraints(decl.typeConstraints);
			if (decl.base != null)
				indexRecoveredTypeSyntax(decl.base);
			for (interfaceType in decl.interfaces)
				indexRecoveredTypeSyntax(interfaceType);
			for (field in decl.fields) {
				if (field.type != null)
					indexRecoveredTypeSyntax(field.type);
			}
		}
		for (fn in program.functions)
			indexRecoveredFunctionTypes(fn);
		for (decl in program.classes)
			for (fn in decl.methods)
				indexRecoveredFunctionTypes(fn);
		for (decl in program.interfaces)
			for (fn in decl.methods)
				indexRecoveredFunctionTypes(fn);
		for (decl in program.abstracts)
			for (fn in decl.methods)
				indexRecoveredFunctionTypes(fn);
	}

	function indexRecoveredFunctionTypes(fn:AstFunction):Void {
		indexRecoveredTypeSyntax(fn.result);
		indexRecoveredTypeConstraints(fn.typeConstraints);
		for (argument in fn.arguments)
			indexRecoveredTypeSyntax(argument.type);
	}

	function indexRecoveredTypeConstraints(constraints:Null<Array<compiler.syntax.Ast.AstTypeConstraint>>):Void {
		if (constraints == null)
			return;
		for (constraint in constraints)
			indexRecoveredTypeSyntax(constraint.type);
	}

	/** Walk all nested source types through the shared exhaustive AST helper. */
	function indexRecoveredTypeSyntax(type:AstType):Void {
		AstChildren.walkType(type, function(child:AstType):Void {
			checkpoint();
			// Resolve each node under the current recovery visibility context.
			// Token-level binding below supplies the exact source span.
			recoveredType(child);
		});
	}

	/**
	 * Reuse identities from the last exact snapshot where the function and
	 * source name still match. This keeps harmless insertions from renumbering
	 * every later local in a recovered editor model. The fallback remains the
	 * existing revision-local ordinal when no safe predecessor exists.
	 */
	function prepareRecoveredLocalReuse(previous:Null<SemanticIndexBuilder>):Void {
		recoveryPreviousLocalIds = [];
		recoveryPreviousLocalSpans = [];
		recoveryUsedLocalIds = [];
		recoveryPreviousLambdaKeys = [];
		recoveryCurrentLambdaOrdinals = [];
		if (previous == null)
			return;
		for (symbol in previous.symbols) {
			var identity = Std.string(symbol.id),
				marker = identity.indexOf(":local:");
			if (marker < 0)
				continue;
			var local = identity.substring(marker + ":local:".length),
				ordinal = local.indexOf(":$" + "l");
			if (ordinal < 0)
				continue;
			var functionKey = local.substring(0, ordinal),
				key = recoveredLocalKey(functionKey, symbol.name),
				ids = recoveryPreviousLocalIds.get(key);
			if (ids == null) {
				ids = [];
				recoveryPreviousLocalIds.set(key, ids);
			}
			ids.push(symbol.id);
			recoveryPreviousLocalSpans.set(Std.string(symbol.id), symbol.declaration);
			if (StringTools.startsWith(functionKey, "$lambda:")) {
				var separator = functionKey.lastIndexOf(":");
				if (separator > "$lambda:".length) {
					var parent = functionKey.substring("$lambda:".length, separator),
						lambdaKeys = recoveryPreviousLambdaKeys.get(parent);
					if (lambdaKeys == null)
						recoveryPreviousLambdaKeys.set(parent, lambdaKeys = []);
					if (lambdaKeys.indexOf(functionKey) < 0)
						lambdaKeys.push(functionKey);
				}
			}
		}
		for (ids in recoveryPreviousLocalIds)
			ids.sort(function(left, right) {
				var leftSpan = recoveryPreviousLocalSpans.get(Std.string(left)),
					rightSpan = recoveryPreviousLocalSpans.get(Std.string(right));
				return Reflect.compare(leftSpan.start, rightSpan.start);
			});
		for (keys in recoveryPreviousLambdaKeys)
			keys.sort(function(left, right) {
				var leftSeparator = left.lastIndexOf(":"),
					rightSeparator = right.lastIndexOf(":"),
					leftStart = Std.parseInt(left.substring(leftSeparator + 1)),
					rightStart = Std.parseInt(right.substring(rightSeparator + 1));
				return leftStart == null || rightStart == null ? Reflect.compare(left, right) : Reflect.compare(leftStart, rightStart);
			});
	}

	static function recoveredLocalKey(functionKey:String, name:String):String
		return functionKey + "\u0000" + name;

	/** Index signatures from a visible module for editor-only recovery queries. */
	public function indexRecoveredModule(program:AstProgram, external:DeclarationIndex, qualifiers:Array<String>, ?token:CancellationToken):Void {
		ensureMutable();
		cancellation = token;
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
			checkpoint();
			addRecoveredFunction(fn.name, fn);
			for (qualifier in qualifiers)
				addRecoveredFunction(qualifier + "." + fn.name, fn);
		}
		for (decl in program.interfaces) {
			checkpoint();
			for (method in decl.methods) {
				indexRecoveredMethod(decl.name, method, qualifiers);
				knownRecoveredMembers.set(decl.name + "." + method.name, true);
			}
		}
		for (decl in program.classes) {
			checkpoint();
			for (field in decl.fields)
				knownRecoveredMembers.set(decl.name + "." + field.name, true);
			for (method in decl.methods) {
				indexRecoveredMethod(decl.name, method, qualifiers);
				knownRecoveredMembers.set(decl.name + "." + method.name, true);
			}
		}
		for (decl in program.abstracts) {
			checkpoint();
			for (method in decl.methods) {
				indexRecoveredMethod(decl.name, method, qualifiers);
				knownRecoveredMembers.set(decl.name + "." + method.name, true);
			}
		}
	}

	function indexRecoveredMethod(owner:String, method:AstFunction, qualifiers:Array<String>):Void {
		var key = owner + "." + method.name;
		addRecoveredFunction(key, method);
		for (qualifier in qualifiers)
			addRecoveredFunction(qualifier + "." + key, method);
	}

	function addRecoveredFunction(name:String, fn:AstFunction):Void {
		if (!recoveredFunctions.exists(name))
			recoveredFunctions.set(name, fn);
	}

	/** Return a signature retained for a current or visible recovered module. */
	public function recoveredSignature(name:String, ?receiverType:CompilerType):Null<SemanticSignatureInfo> {
		var substitutions:Null<Map<String, CompilerType>> = receiverType == null ? null : recoveredTypeSubstitutions(receiverType),
			fn:Null<AstFunction> = null,
			separator = name.lastIndexOf(".");
		if (receiverType != null && separator > 0) {
			var resolved = recoveredMethodWithSubstitutions(name.substring(0, separator), name.substring(separator + 1), [],
				substitutions == null ? [] : substitutions);
			if (resolved != null) {
				fn = resolved.method;
				substitutions = resolved.substitutions;
			}
		}
		if (fn == null)
			fn = recoveredFunction(name);
		if (fn == null)
			fn = recoveredFunction(name + ".new");
		if (fn == null)
			return null;
		var parameters = [
			for (argument in fn.arguments)
				argument.name + ":" + (substitutions == null ? displayAstType(argument.type) : displayType(recoveredType(argument.type, substitutions)))
		];
		return {
			label: sourceName(name) + "(" + parameters.join(",") + "):" + (substitutions == null ? displayAstType(fn.result) : displayType(recoveredType(fn.result, substitutions))),
			parameters: parameters,
			result: substitutions == null ? displayAstType(fn.result) : displayType(recoveredType(fn.result, substitutions))
		};
	}

	/** Build a display signature for a callable local recovered from an expression. */
	public function callableSignature(type:Null<CompilerType>, name:String):Null<SemanticSignatureInfo> {
		return switch type {
			case TFunction(arguments, result):
				var parameters = [for (index in 0...arguments.length) "arg" + index + ":" + displayType(arguments[index])],
					resultName = displayType(result);
				{
					label: name + "(" + parameters.join(",") + "):" + resultName,
					parameters: parameters,
					result: resultName
				};
			case TNullable(element): callableSignature(element, name);
			default: null;
		};
	}

	function rememberRecoveredMember(owner:String, name:String, span:SourceSpan):Void
		for (symbol in symbols)
			if (sourceName(symbol.name) == name && symbol.declaration.start >= span.start && symbol.declaration.end <= span.end) {
				recoveredMembers.set(owner + "." + name, symbol.id);
				return;
			}

	function indexRecoveredFunction(fn:AstFunction, owner:Null<String>, ?ownerTypeParameters:Array<String>):Void {
		var functionKey = (owner == null ? "" : owner + ".") + fn.name;
		currentRecoveredFunctionKey = functionKey;
		currentRecoveredTypeParameters = [];
		if (ownerTypeParameters != null)
			for (name in ownerTypeParameters)
				currentRecoveredTypeParameters.set(name, TTypeParameter(owner, name));
		if (fn.typeParameters != null)
			for (name in fn.typeParameters) {
				currentRecoveredTypeParameters.set(name, TTypeParameter(functionKey, name));
				rememberRecoveredTypeParameter(name, fn.span, functionKey);
			}
		recoveredLocalNext.set(functionKey, owner != null && !fn.isStatic ? 1 : 0);
		var functionId = recoveredDeclaredSymbol(functionKey);
		if (functionId != null) {
			var parameters = [
				for (argument in fn.arguments)
					argument.name + ":" + displayAstType(argument.type)
			];
			setDeclaredSignature(functionKey, fn.name + "(" + parameters.join(", ") + "):" + displayAstType(fn.result), parameters, displayAstType(fn.result));
		}
		for (argument in fn.arguments)
			addRecoveredLocal(functionKey, argument.name, recoveredType(argument.type), argument.span, fn.span, 0);
		if (owner != null && !fn.isStatic)
			functionReceivers.push({span: fn.span, type: recoveredReceiverType(owner, ownerTypeParameters)});
		indexRecoveredStatements(functionKey, fn.statements, fn.span, 0);
		currentCaller = recoveredDeclaredSymbol(functionKey);
		indexRecoveredStatementUses(fn.statements, recoveredType(fn.result));
		var tokenIndex = firstTokenAtOrAfter(fn.span.start);
		while (tokenIndex < tokens.length) {
			var token = tokens[tokenIndex++];
			if (token.span.start > fn.span.end)
				break;
			if (token.kind == TokenKind.Identifier && token.span.end <= fn.span.end)
				bindRecoveredLocal(token.text, token.span);
		}
		currentCaller = null;
		currentRecoveredFunctionKey = "";
		currentRecoveredTypeParameters = [];
	}

	/**
	 * Keep the receiver's declaration kind and generic context while indexing a
	 * recovered method. A plain Class<T> receiver is incorrect for interface or
	 * abstract methods, and dropping owner type parameters prevents recovered
	 * member signatures from being substituted inside generic methods.
	 */
	function recoveredReceiverType(owner:String, ownerTypeParameters:Null<Array<String>>):CompilerType {
		var parameters = ownerTypeParameters == null ? [] : ownerTypeParameters,
			arguments:Array<CompilerType> = [
				for (parameter in parameters)
					currentRecoveredTypeParameters.exists(parameter) ? currentRecoveredTypeParameters.get(parameter) : TUnknown
			];
		if (declarations.abstracts.exists(owner)) {
			var substitutions:Map<String, CompilerType> = [];
			for (index in 0...parameters.length)
				substitutions.set(parameters[index], arguments[index]);
			return TAbstract(owner, arguments, recoveredType(declarations.abstracts.get(owner).underlying, substitutions));
		}
		var kind = declarations.interfaces.exists(owner) ? compiler.types.Type.NominalKind.Interface : compiler.types.Type.NominalKind.Class;
		return TInstance(kind, owner, arguments);
	}

	function typedReceiverType(owner:String, span:SourceSpan):CompilerType {
		var parameters = ownerTypeParameters(owner),
			arguments:Array<CompilerType> = [for (parameter in parameters) TTypeParameter(owner, parameter)];
		if (declarations.abstracts.exists(owner)) {
			var substitutions:Map<String, CompilerType> = [];
			for (index in 0...parameters.length)
				substitutions.set(parameters[index], arguments[index]);
			return TAbstract(owner, arguments, declarations.resolve(declarations.abstracts.get(owner).underlying, span, substitutions));
		}
		if (declarations.interfaces.exists(owner))
			return TInstance(compiler.types.Type.NominalKind.Interface, owner, arguments);
		return TInstance(compiler.types.Type.NominalKind.Class, owner, arguments);
	}

	function ownerTypeParameters(owner:String):Array<String> {
		var classDeclaration = declarations.classes.get(owner);
		if (classDeclaration != null)
			return classDeclaration.typeParameters;
		var interfaceDeclaration = declarations.interfaces.get(owner);
		if (interfaceDeclaration != null)
			return interfaceDeclaration.typeParameters;
		var abstractDeclaration = declarations.abstracts.get(owner);
		return abstractDeclaration == null ? [] : abstractDeclaration.typeParameters;
	}

	function hasFunctionReceiver(span:SourceSpan):Bool {
		for (candidate in functionReceivers)
			if (candidate.span.start == span.start && candidate.span.end == span.end)
				return true;
		return false;
	}

	function rememberRecoveredTypeParameters(parameters:Null<Array<String>>, span:SourceSpan, ?owner:String):Void {
		if (parameters == null)
			return;
		for (name in parameters)
			rememberRecoveredTypeParameter(name, span, owner);
	}

	function rememberRecoveredTypeParameter(name:String, span:SourceSpan, ?owner:String):Void {
		if (name.length == 0)
			return;
		for (existing in recoveredTypeParameterScopes)
			if (existing.name == name && existing.owner == (owner == null ? "" : owner)
				&& existing.span.start == span.start && existing.span.end == span.end)
				return;
		recoveredTypeParameterScopes.push({name: name, owner: owner == null ? "" : owner, span: span});
	}

	static function typeParameterKey(owner:String, name:String):String
		return owner + ":" + name;

	function typeParameterAt(position:Int, name:String):Null<SemanticSymbolId> {
		var selected:Null<SemanticRecoveredTypeParameterScope> = null;
		for (candidate in recoveredTypeParameterScopes) {
			if (candidate.name != name || position < candidate.span.start || position > candidate.span.end)
				continue;
			if (selected == null || candidate.span.end - candidate.span.start < selected.span.end - selected.span.start)
				selected = candidate;
		}
		return selected == null ? null : typeParameterIds.get(typeParameterKey(selected.owner, name));
	}

	function recoveredDeclaredSymbol(name:String):Null<SemanticSymbolId> {
		var ids = symbolIdsByName.get(name);
		if (ids != null)
			for (id in ids)
				if (Std.string(id).indexOf(":local:") < 0
					&& symbols.get(id).kind != DeclarationKind.TypeParameter)
					return id;
		return null;
	}

	function firstTokenAtOrAfter(start:Int):Int {
		var low = 0, high = tokens.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (tokens[middle].span.start < start)
				low = middle + 1;
			else
				high = middle;
		}
		return low;
	}

	function resolveRecoveredSymbol(name:String):Null<SemanticSymbolId>
		return resolvedRecoveredSymbol(name);

	function resolveRecoveredEnumCase(name:String, index:Int):Null<SemanticSymbolId> {
		for (declaration in declarations.enums)
			if (declaration.name == name && index >= 0 && index < declaration.cases.length) {
				var local = recoveredDeclaredSymbol(name + "." + declaration.cases[index].name);
				if (local != null)
					return local;
			}
		return recoveryResolveEnumCase == null ? null : recoveryResolveEnumCase(name, index);
	}

	function resolvedRecoveredSymbol(name:String):Null<SemanticSymbolId> {
		var local = recoveredDeclaredSymbol(name);
		return local == null && recoveryResolve != null ? recoveryResolve(name) : local;
	}

	function indexRecoveredStatements(functionKey:String, statements:Array<AstStatement>, scope:SourceSpan, depth:Int):Void {
		for (statement in statements) {
			checkpoint();
			switch statement {
				case UninitializedDeclaration(name, type, span):
					indexRecoveredTypeSyntax(type);
					addRecoveredLocal(functionKey, name, recoveredType(type), span, scope, depth);
				case VarDeclaration(name, type, initializer, span):
					if (type != null)
						indexRecoveredTypeSyntax(type);
					var localType = type == null ? recoveredExpressionType(initializer) : recoveredType(type);
					addRecoveredLocal(functionKey, name, localType, span, scope, depth);
					if (type != null)
						completionTypes.push({span: span, type: localType});
				case If(_, yes, no, span):
					indexRecoveredStatements(functionKey, yes, span, depth + 1);
					indexRecoveredStatements(functionKey, no, span, depth + 1);
				case While(_, body, span), DoWhile(body, _, span):
					indexRecoveredStatements(functionKey, body, span, depth + 1);
				case ForIn(name, valueName, iterable, body, span):
					var iterableType = recoveredExpressionType(iterable),
						keyType = recoveredForInKeyType(iterableType, valueName);
					addRecoveredLocal(functionKey, name, keyType, span, span, depth + 1);
					if (valueName != null)
						addRecoveredLocal(functionKey, valueName, recoveredForInValueType(iterableType), span, span, depth + 1);
					indexRecoveredStatements(functionKey, body, span, depth + 1);
				case Try(body, catches, span):
					indexRecoveredStatements(functionKey, body, span, depth + 1);
					for (caught in catches) {
						indexRecoveredTypeSyntax(caught.type);
						addRecoveredLocal(functionKey, caught.name, recoveredType(caught.type), caught.span, caught.span, depth + 1);
						indexRecoveredStatements(functionKey, caught.statements, caught.span, depth + 1);
					}
				case Switch(value, cases, fallback, _, span):
					var subjectType = recoveredExpressionType(value);
					for (item in cases) {
						indexRecoveredPatternBindings(functionKey, item.value, subjectType, item.span, depth + 1);
						indexRecoveredStatements(functionKey, item.statements, item.span, depth + 1);
					}
					indexRecoveredStatements(functionKey, fallback, span, depth + 1);
				case ErrorStatement(_), Assignment(_, _, _), IndexAssignment(_, _, _, _), FieldAssignment(_, _, _, _), Return(_, _), ReturnVoid(_),
					Throw(_, _), Break(_), Continue(_), Increment(_, _, _), Expression(_, _):
			}
		}
	}

	function addRecoveredLocal(functionKey:String, name:String, type:CompilerType, declaration:SourceSpan, scope:SourceSpan, depth:Int):Void {
		var token = declarationToken(tokens, declaration, name);
		if (token == null)
			return;
		var id = reusedRecoveredLocalId(functionKey, name, token.span);
		if (id == null) {
			var next = recoveredLocalNext.exists(functionKey) ? recoveredLocalNext.get(functionKey) : 0;
			do {
				id = new SemanticSymbolId(module, 'local:' + functionKey + ':' + '$' + 'l' + next + ':' + name);
				next++;
			} while (symbols.exists(id));
			recoveredLocalNext.set(functionKey, next);
		}
		if (!symbols.exists(id)) {
			symbols.set(id, {
				id: id,
				name: name,
				kind: DeclarationKind.Member,
				declaration: token.span
			});
			addSymbolName(name, id);
			bind(id, token.span);
			declarationTypes.set(id, type);
		}
		addCompletionLocal(name, type, declaration, scope, depth);
	}

	function reusedRecoveredLocalId(functionKey:String, name:String, span:SourceSpan):Null<SemanticSymbolId> {
		var candidates = recoveryPreviousLocalIds.get(recoveredLocalKey(functionKey, name));
		if (candidates == null)
			return null;
		// Exact token spans are the strongest evidence that this is the same
		// binding; this also handles edits that only damage a later expression.
		for (candidate in candidates) {
			var key = Std.string(candidate), previousSpan = recoveryPreviousLocalSpans.get(key);
			if (!recoveryUsedLocalIds.exists(key) && previousSpan.start == span.start && previousSpan.end == span.end) {
				recoveryUsedLocalIds.set(key, true);
				return candidate;
			}
		}
		// If source offsets moved, preserve identity by source name and lexical
		// occurrence. Unrelated declarations therefore do not renumber it.
		for (candidate in candidates) {
			var key = Std.string(candidate);
			if (!recoveryUsedLocalIds.exists(key)) {
				recoveryUsedLocalIds.set(key, true);
				return candidate;
			}
		}
		return null;
	}

	function indexRecoveredStatementUses(statements:Array<AstStatement>, ?expectedReturn:CompilerType, ?functionKey:String):Void {
		var activeFunctionKey = functionKey == null ? currentRecoveredFunctionKey : functionKey;
		for (statement in statements) {
			checkpoint();
			switch statement {
				case VarDeclaration(_, type, value, span):
					if (type != null)
						completionTypes.push({span: span, type: recoveredType(type)});
					indexRecoveredExpression(value, type == null ? null : recoveredType(type), activeFunctionKey);
				case Return(value, span):
					indexRecoveredExpression(value, expectedReturn, activeFunctionKey);
				case Throw(value, _), Expression(value, _):
					indexRecoveredExpression(value, null, activeFunctionKey);
				case Assignment(name, value, span):
					bindRecoveredLocal(name, span);
					indexRecoveredExpression(value, recoveredLocalType(name, span), activeFunctionKey);
				case Increment(name, _, span):
					bindRecoveredLocal(name, span);
				case IndexAssignment(array, offset, value, _):
					indexRecoveredExpression(array, null, activeFunctionKey);
					indexRecoveredExpression(offset, TInt, activeFunctionKey);
					indexRecoveredExpression(value, indexedValueType(recoveredExpressionType(array)), activeFunctionKey);
				case FieldAssignment(object, field, value, span):
					bindRecoveredMember(object, field, span);
					indexRecoveredExpression(object, null, activeFunctionKey);
					indexRecoveredExpression(value, recoveredMemberType(object, field), activeFunctionKey);
				case If(predicate, yes, no, _):
					indexRecoveredExpression(predicate, TBool, activeFunctionKey);
					indexRecoveredStatementUses(yes, expectedReturn, activeFunctionKey);
					indexRecoveredStatementUses(no, expectedReturn, activeFunctionKey);
				case While(predicate, body, _):
					indexRecoveredExpression(predicate, TBool, activeFunctionKey);
					indexRecoveredStatementUses(body, expectedReturn, activeFunctionKey);
				case DoWhile(body, predicate, _):
					indexRecoveredStatementUses(body, expectedReturn, activeFunctionKey);
					indexRecoveredExpression(predicate, TBool, activeFunctionKey);
				case ForIn(_, _, iterable, body, _):
					indexRecoveredExpression(iterable, null, activeFunctionKey);
					indexRecoveredStatementUses(body, expectedReturn, activeFunctionKey);
				case Try(body, catches, _):
					indexRecoveredStatementUses(body, expectedReturn, activeFunctionKey);
					for (caught in catches)
						indexRecoveredStatementUses(caught.statements, expectedReturn, activeFunctionKey);
				case Switch(value, cases, fallback, _, _):
					var expectedPattern = recoveredExpressionType(value);
					indexRecoveredExpression(value, null, activeFunctionKey);
					for (item in cases) {
						indexRecoveredExpression(item.value, expectedPattern, activeFunctionKey);
						if (item.guard != null)
							indexRecoveredExpression(item.guard, null, activeFunctionKey);
						indexRecoveredStatementUses(item.statements, expectedReturn, activeFunctionKey);
					}
					indexRecoveredStatementUses(fallback, expectedReturn, activeFunctionKey);
				case ErrorStatement(_), UninitializedDeclaration(_, _, _), ReturnVoid(_), Break(_), Continue(_):
			}
		}
	}

	function indexRecoveredExpression(expression:AstExpression, ?expected:CompilerType, ?functionKey:String):Void {
		var activeFunctionKey = functionKey == null ? currentRecoveredFunctionKey : functionKey;
		checkpoint();
		switch expression {
			case ErrorExpression(span):
				if (expected != null)
					completionTypes.push({span: span, type: expected});
			case Variable(name, span):
				var separator = name.indexOf(".");
				if (separator < 0) {
					var local = bindRecoveredLocal(name, span);
					if (local == null) {
						var declaration = resolvedRecoveredSymbol(name);
						if (declaration != null)
							bind(declaration, referenceToken(tokens, span, name) == null ? span : referenceToken(tokens, span, name).span);
						else
							recordUnresolved(name, span);
					}
				} else {
					var receiver = name.substring(0, separator),
						member = name.substring(name.lastIndexOf(".") + 1);
					bindRecoveredReceiver(receiver, span);
					if (bindRecoveredMember(Variable(receiver, span), member, span) == null)
						bindNamed(resolveRecoveredSymbol, name, span);
				}
			case Member(object, name, span):
				indexRecoveredExpression(object, null, activeFunctionKey);
				if (bindRecoveredMember(object, name, span) == null && name.length > 0 && !isKnownRecoveredMember(object, name))
					recordUnresolved(name, span);
			case Call(name, arguments, span):
				var separator = name.lastIndexOf(".");
				if (separator > 0) {
					var receiverName = name.substring(0, separator),
						memberName = name.substring(separator + 1),
						receiver = Variable(receiverName, span);
					bindRecoveredReceiver(receiverName, span);
					var receiverType = recoveredExpressionBindingType(receiver),
						callee = bindRecoveredMember(receiver, memberName, span);
					if (callee == null)
						callee = bindNamed(resolveRecoveredSymbol, name, span);
					var owner = memberOwner(receiverType),
						method = owner == null ? null : recoveredMethodWithSubstitutions(owner, memberName, [], recoveredTypeSubstitutions(receiverType));
					if (callee == null && !isKnownRecoveredMember(receiver, memberName))
						recordUnresolved(memberName, span);
					addCall(callee, span, memberName);
					indexRecoveredCallArguments(arguments, method == null ? null : method.method, method == null ? null : method.substitutions,
						method == null ? recoveredBuiltinMethodArguments(receiverType, memberName) : null, activeFunctionKey, expected);
				} else {
					var local = bindRecoveredLocal(name, span);
					var localType:Null<CompilerType> = local == null ? null : recoveredLocalType(name, span);
					if (local == null) {
						var callee = resolvedRecoveredSymbol(name);
						if (callee != null) {
							var token = referenceToken(tokens, span, sourceName(name));
							if (token != null)
								bind(callee, token.span);
							addCall(callee, span, name);
						} else
							recordUnresolved(name, span);
					}
					if (localType != null)
						for (index in 0...arguments.length)
							indexRecoveredExpression(arguments[index], expectedFunctionArgument(localType, index), activeFunctionKey);
					else
						indexRecoveredCallArguments(arguments, recoveredFunctionForCall(name), null, recoveredBuiltinCallArguments(name), activeFunctionKey, expected);
				}
			case ClosureCall(callee, arguments, _):
				indexRecoveredExpression(callee, null, activeFunctionKey);
				for (index in 0...arguments.length)
					indexRecoveredExpression(arguments[index], expectedFunctionArgument(recoveredExpressionType(callee), index), activeFunctionKey);
			case MethodCall(object, name, arguments, span):
				indexRecoveredExpression(object, null, activeFunctionKey);
				var callee = bindRecoveredMember(object, name, span);
				addCall(callee, span, name);
				if (callee == null && !isKnownRecoveredMember(object, name))
					recordUnresolved(name, span);
				var receiverType = recoveredExpressionBindingType(object),
					owner = memberOwner(receiverType),
					method = owner == null ? null : recoveredMethodWithSubstitutions(owner, name, [], recoveredTypeSubstitutions(receiverType)),
					memberArguments = method == null ? anonymousFunctionArguments(anonymousMemberType(receiverType, name)) : null;
				indexRecoveredCallArguments(arguments, method == null ? null : method.method, method == null ? null : method.substitutions,
					method == null ? (memberArguments == null ? recoveredBuiltinMethodArguments(receiverType, name) : memberArguments) : null,
					activeFunctionKey, expected);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _):
				indexRecoveredExpression(left, expected, activeFunctionKey);
				indexRecoveredExpression(right, expected, activeFunctionKey);
			case BitAnd(left, right, _), BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _),
				UnsignedShiftRight(left, right, _):
				indexRecoveredExpression(left, TInt, activeFunctionKey);
				indexRecoveredExpression(right, TInt, activeFunctionKey);
			case Less(left, right, _), LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _),
				NotEqual(left, right, _):
				indexRecoveredExpression(left, null, activeFunctionKey);
				indexRecoveredExpression(right, null, activeFunctionKey);
			case And(left, right, _), Or(left, right, _):
				indexRecoveredExpression(left, TBool, activeFunctionKey);
				indexRecoveredExpression(right, TBool, activeFunctionKey);
			case Index(array, offset, _):
				indexRecoveredExpression(array, expected == null ? null : TArray(expected), activeFunctionKey);
				indexRecoveredExpression(offset, TInt, activeFunctionKey);
			case Range(start, finish, _):
				indexRecoveredExpression(start, null, activeFunctionKey);
				indexRecoveredExpression(finish, null, activeFunctionKey);
			case Negate(value, _), PostfixIncrement(value, _, _):
				indexRecoveredExpression(value, expected, activeFunctionKey);
			case Not(value, _):
				indexRecoveredExpression(value, TBool, activeFunctionKey);
			case ThrowExpression(value, _):
				indexRecoveredExpression(value, null, activeFunctionKey);
			case Cast(value, target, _):
				if (target != null)
					indexRecoveredTypeSyntax(target);
				indexRecoveredExpression(value, target == null ? expected : recoveredType(target), activeFunctionKey);
			case Conditional(predicate, yes, no, _):
				indexRecoveredExpression(predicate, TBool, activeFunctionKey);
				indexRecoveredExpression(yes, expected, activeFunctionKey);
				indexRecoveredExpression(no, expected, activeFunctionKey);
			case BlockExpression(statements, result, _):
				indexRecoveredStatementUses(statements, expected, activeFunctionKey);
				indexRecoveredExpression(result, expected, activeFunctionKey);
			case ArrayLiteral(values, _):
				for (value in values)
					indexRecoveredExpression(value, indexedValueType(expected), activeFunctionKey);
			case ObjectLiteral(fields, _):
				for (field in fields)
					indexRecoveredExpression(field.value, expectedFieldType(expected, field.name), activeFunctionKey);
			case MapLiteral(entries, _):
				for (entry in entries) {
					indexRecoveredExpression(entry.key, mapKeyType(expected), activeFunctionKey);
					indexRecoveredExpression(entry.value, mapValueType(expected), activeFunctionKey);
				}
			case ArrayComprehension(keyName, valueName, iterable, predicate, value, span):
				var iterableType = recoveredExpressionType(iterable),
					keyType = recoveredForInKeyType(iterableType, valueName);
				indexRecoveredExpression(iterable, null, activeFunctionKey);
				addRecoveredLocal(activeFunctionKey, keyName, keyType, span, span, 1);
				if (valueName != null)
					addRecoveredLocal(activeFunctionKey, valueName, recoveredForInValueType(iterableType), span, span, 1);
				if (predicate != null)
					indexRecoveredExpression(predicate, TBool, activeFunctionKey);
				indexRecoveredExpression(value, indexedValueType(expected), activeFunctionKey);
			case MapComprehension(keyName, valueName, iterable, predicate, key, value, span):
				var iterableType = recoveredExpressionType(iterable),
					keyType = recoveredForInKeyType(iterableType, valueName);
				indexRecoveredExpression(iterable, null, activeFunctionKey);
				addRecoveredLocal(activeFunctionKey, keyName, keyType, span, span, 1);
				if (valueName != null)
					addRecoveredLocal(activeFunctionKey, valueName, recoveredForInValueType(iterableType), span, span, 1);
				if (predicate != null)
					indexRecoveredExpression(predicate, TBool, activeFunctionKey);
				indexRecoveredExpression(key, mapKeyType(expected), activeFunctionKey);
				indexRecoveredExpression(value, mapValueType(expected), activeFunctionKey);
			case New(name, arguments, span):
				var callee = bindNamed(resolveRecoveredSymbol, name, span),
					constructionType = recoveredConstructionType(name, expected);
				addCall(callee, span, name);
				indexRecoveredCallArguments(arguments, recoveredFunctionForCall(name), recoveredTypeSubstitutions(constructionType), null,
					activeFunctionKey, expected);
			case NewGeneric(name, typeArguments, arguments, span):
				for (typeArgument in typeArguments)
					indexRecoveredTypeSyntax(typeArgument);
				var callee = bindNamed(resolveRecoveredSymbol, name, span),
					constructionType = recoveredGenericConstructionType(name, typeArguments, expected);
				addCall(callee, span, name);
				indexRecoveredCallArguments(arguments, recoveredFunctionForCall(name), recoveredTypeSubstitutions(constructionType), null,
					activeFunctionKey, expected);
			case NewArray(element, length, _):
				indexRecoveredTypeSyntax(element);
				indexRecoveredExpression(length, TInt, activeFunctionKey);
			case NewMap(key, value, _):
				indexRecoveredTypeSyntax(key);
				indexRecoveredTypeSyntax(value);
			case NativeLayoutQuery(_, type, _, _):
				indexRecoveredTypeSyntax(type);
			case Lambda(arguments, body, span):
				indexRecoveredLambda(activeFunctionKey, arguments, body, span, expected);
			case SwitchExpression(value, cases, fallback, _):
				var expectedPattern = recoveredExpressionType(value);
				indexRecoveredExpression(value, null, activeFunctionKey);
				for (item in cases) {
					indexRecoveredPatternBindings(activeFunctionKey, item.value, expectedPattern, item.span, 1);
					indexRecoveredExpression(item.value, expectedPattern, activeFunctionKey);
					if (item.guard != null)
						indexRecoveredExpression(item.guard, null, activeFunctionKey);
					indexRecoveredExpression(item.result, expected, activeFunctionKey);
				}
				if (fallback != null)
					indexRecoveredExpression(fallback, expected, activeFunctionKey);
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_), Unreachable(_):
		}
	}

	/** Index a lambda as a nested lexical scope in the recovered editor model. */
	function indexRecoveredLambda(parentFunctionKey:String, arguments:Array<compiler.syntax.Ast.AstArgument>, body:Array<AstStatement>,
			span:SourceSpan, expected:Null<CompilerType>):Void {
		var ordinal = recoveryCurrentLambdaOrdinals.exists(parentFunctionKey) ? recoveryCurrentLambdaOrdinals.get(parentFunctionKey) : 0,
			previousKeys = recoveryPreviousLambdaKeys.get(parentFunctionKey),
			currentKey = "$lambda:" + parentFunctionKey + ":" + span.start,
			lambdaKey = previousKeys != null && ordinal < previousKeys.length ? previousKeys[ordinal] : currentKey;
		recoveryCurrentLambdaOrdinals.set(parentFunctionKey, ordinal + 1);
		var expectedArguments:Array<CompilerType> = switch expected {
				case TFunction(values, _): values;
				case TNullable(TFunction(values, _)): values;
				default: [];
			};
		for (index in 0...arguments.length) {
			var argument = arguments[index],
				argumentType:CompilerType = switch argument.type {
					case InferredType if (index < expectedArguments.length): expectedArguments[index];
					case InferredType: TUnknown;
					default: recoveredType(argument.type);
				};
			indexRecoveredTypeSyntax(argument.type);
			if (argument.name != "_")
				addRecoveredLocal(lambdaKey, argument.name, argumentType, argument.span, span, 1);
		}
		indexRecoveredStatements(lambdaKey, body, span, 1);
		indexRecoveredStatementUses(body, functionResultType(expected), lambdaKey);
	}

	function bindRecoveredLocal(name:String, span:SourceSpan):Null<SemanticSymbolId> {
		var found:Null<SemanticCompletionLocal> = null;
		for (local in completionLocals) {
			checkpoint();
			if (local.name == name
				&& local.declaration.start <= span.start
				&& span.start >= local.scope.start
				&& span.end <= local.scope.end
				&& (found == null
					|| local.depth > found.depth
					|| local.depth == found.depth
					&& local.declaration.start > found.declaration.start))
				found = local;
		}
		if (found == null)
			return null;
		for (symbol in symbols)
			if (symbol.name == name && symbol.declaration.start == found.declaration.start) {
				var token = referenceToken(tokens, span, name);
				if (token != null)
					bind(symbol.id, token.span);
				return symbol.id;
			}
		return null;
	}

	/**
		Bind a receiver that may be either a lexical local or a qualified type.
		Recovered calls represent static access as one dotted name, so the type
		component needs its own binding for type-definition queries.
	*/
	function bindRecoveredReceiver(name:String, span:SourceSpan):Null<SemanticSymbolId> {
		var local = bindRecoveredLocal(name, span);
		if (local != null)
			return local;
		var type = recoveredType(NamedType(name));
		return isRecoveryType(type) ? null : bindNamed(resolveRecoveredSymbol, name, span);
	}

	function bindRecoveredMember(object:AstExpression, name:String, span:SourceSpan):Null<SemanticSymbolId> {
		var receiverType = recoveredExpressionBindingType(object),
			owner = switch receiverType {
				case TNullable(element): memberOwner(element);
				case type: memberOwner(type);
			};
		if (owner == null)
			return null;
		var id = recoveredMemberSymbol(receiverType, name, []);
		if (id == null && recoveryResolve != null)
			id = recoveryResolve(owner + "." + name);
		if (id == null)
			return null;
		var token = referenceToken(tokens, span, name);
		if (token != null)
			bind(id, token.span);
		return id;
	}

	function isKnownRecoveredMember(object:AstExpression, name:String):Bool {
		var receiverType = recoveredExpressionBindingType(object),
			anonymous = anonymousMemberType(receiverType, name),
			owner = switch receiverType {
				case TNullable(element): memberOwner(element);
				case type: memberOwner(type);
			};
		return anonymous != null || owner != null
			&& (recoveredMemberSymbol(receiverType, name, []) != null
				|| knownRecoveredMembers.exists(owner + "." + name)
				|| recoveredFieldType(owner, name, []) != null
				|| recoveredMethod(owner, name, []) != null);
	}

	function recoveredMemberSymbol(type:CompilerType, name:String, visiting:Array<String>):Null<SemanticSymbolId> {
		var owner = switch type {
			case TNullable(element): memberOwner(element);
			case value: memberOwner(value);
		};
		if (owner == null || visiting.indexOf(owner) >= 0)
			return null;
		var direct = recoveredMembers.get(owner + "." + name);
		if (direct != null)
			return direct;
		direct = recoveredDeclaredSymbol(owner + "." + name);
		if (direct != null)
			return direct;
		var nextVisiting = visiting.copy();
		nextVisiting.push(owner);
		var substitutions = recoveredTypeSubstitutions(type),
			classDecl = declarations.classes.get(owner);
		if (classDecl != null && classDecl.base != null) {
			var baseType = recoveredType(classDecl.base, substitutions),
				inherited = recoveredMemberSymbol(baseType, name, nextVisiting);
			if (inherited != null)
				return inherited;
		}
		if (classDecl != null)
			for (interfaceAstType in classDecl.interfaces) {
				var interfaceType = recoveredType(interfaceAstType, substitutions),
					inherited = recoveredMemberSymbol(interfaceType, name, nextVisiting);
				if (inherited != null)
					return inherited;
			}
		var interfaceDecl = declarations.interfaces.get(owner);
		if (interfaceDecl != null)
			for (base in interfaceDecl.bases) {
				var baseType = recoveredType(base, substitutions),
					inherited = recoveredMemberSymbol(baseType, name, nextVisiting);
				if (inherited != null)
					return inherited;
			}
		return null;
	}

	function recoveredExpressionBindingType(expression:AstExpression):CompilerType
		return switch expression {
			case Variable("this", span):
				var receiver:Null<CompilerType> = null;
				for (candidate in functionReceivers)
					if (span.start >= candidate.span.start && span.end <= candidate.span.end)
						receiver = candidate.type;
				receiver == null ? TUnknown : receiver;
			case Variable(name, span):
				var id = bindRecoveredLocal(name, span);
				if (id != null && declarationTypes.exists(id)) declarationTypes.get(id); else if (declarations.classes.exists(name))
					TInstance(compiler.types.Type.NominalKind.Class, name,
					[]); else if (declarations.interfaces.exists(name)) TInstance(compiler.types.Type.NominalKind.Interface, name, []);
				else {
					var functionType = recoveredFunctionType(name);
					functionType == null ? TUnknown : functionType;
				}
			case New(name, _, _): TInstance(compiler.types.Type.NominalKind.Class, name, []);
			case NewGeneric(name, typeArguments, _, _): recoveredType(AppliedType(name, typeArguments));
			default: recoveredExpressionType(expression);
		};

	function recoveredConstructionType(name:String, ?expected:CompilerType):CompilerType {
		return switch expected {
			case TInstance(_, expectedName, _) if (sourceName(expectedName) == sourceName(name)): expected;
			case TAbstract(expectedName, _, _) if (sourceName(expectedName) == sourceName(name)): expected;
			default: TInstance(compiler.types.Type.NominalKind.Class, name, []);
		};
	}

	function recoveredGenericConstructionType(name:String, typeArguments:Array<AstType>, ?expected:CompilerType):CompilerType {
		var inferred = recoveredType(AppliedType(name, typeArguments));
		return switch expected {
			case TInstance(_, expectedName, _) if (sourceName(expectedName) == sourceName(name)
				&& (typeArguments.length == 0 || isRecoveryType(inferred))): expected;
			case TAbstract(expectedName, _, _) if (sourceName(expectedName) == sourceName(name)
				&& (typeArguments.length == 0 || isRecoveryType(inferred))): expected;
			default: inferred;
		};
	}

	function recoveredLambdaType(arguments:Array<compiler.syntax.Ast.AstArgument>, ?expected:CompilerType):CompilerType {
		var expectedArguments:Array<CompilerType> = [],
			expectedResult:CompilerType = TUnknown;
		switch expected {
			case TFunction(values, result):
				expectedArguments = values;
				expectedResult = result;
			case TNullable(TFunction(values, result)):
				expectedArguments = values;
				expectedResult = result;
			default:
		}
		return TFunction([
			for (index in 0...arguments.length)
				switch arguments[index].type {
					case InferredType if (index < expectedArguments.length): expectedArguments[index];
					default: recoveredType(arguments[index].type);
				}
		], expectedResult);
	}

	function recoveredSwitchExpressionType(cases:Array<compiler.syntax.Ast.AstSwitchExpressionCase>, fallback:Null<AstExpression>,
			expected:Null<CompilerType>):CompilerType {
		var result:Null<CompilerType> = expected != null && !isRecoveryType(expected) ? expected : null;
		for (item in cases) {
			var candidate = recoveredExpressionType(item.result, expected);
			if (result == null)
				result = candidate;
			else if (expected == null || isRecoveryType(expected))
				result = recoveredCommonType(result, candidate);
		}
		if (fallback != null) {
			var candidate = recoveredExpressionType(fallback, expected);
			if (result == null)
				result = candidate;
			else if (expected == null || isRecoveryType(expected))
				result = recoveredCommonType(result, candidate);
		}
		return result == null ? TUnknown : result;
	}

	function recoveredExpressionType(expression:AstExpression, ?expected:CompilerType):CompilerType
		return switch expression {
			case ErrorExpression(_): TError;
			case IntegerLiteral(_, _): TInt;
			case FloatLiteral(_, _): TFloat;
			case StringLiteral(_, _): TString;
			case BoolLiteral(_, _): TBool;
			case NullLiteral(_): TNull;
			case Unreachable(_): TNever;
			case Variable(name, span): recoveredExpressionBindingType(Variable(name, span));
			case Member(object, name, _): recoveredMemberType(object, name);
			case MethodCall(object, name, arguments, _):
				var receiverType = recoveredExpressionBindingType(object),
					builtinResult = recoveredBuiltinMethodResult(receiverType, name),
					anonymousMember = anonymousMemberType(receiverType, name),
					owner = memberOwner(receiverType);
			if (builtinResult != null)
				builtinResult;
			else if (anonymousMember != null)
				recoveredCallableResult(anonymousMember, expected);
			else {
				var method = owner == null ? null : recoveredMethodWithSubstitutions(owner, name, [], recoveredTypeSubstitutions(receiverType));
				method == null ? (expected != null && !isRecoveryType(expected) ? expected : TUnknown)
					: recoveredCallResult(method.method, method.substitutions, arguments, expected);
			}
			case Call(name, arguments, span):
				var separator = name.lastIndexOf(".");
				if (separator > 0) {
					var receiverName = name.substring(0, separator),
						memberName = name.substring(separator + 1),
						receiverType = recoveredExpressionBindingType(Variable(receiverName, span)),
						builtinResult = recoveredBuiltinMethodResult(receiverType, memberName),
						owner = memberOwner(receiverType),
						method = owner == null ? null : recoveredMethodWithSubstitutions(owner, memberName, [], recoveredTypeSubstitutions(receiverType));
					if (builtinResult != null)
						builtinResult;
					else if (method != null)
						recoveredCallResult(method.method, method.substitutions, arguments, expected);
					else {
						var direct = recoveredFunction(name);
						var result = direct == null ? recoveredBuiltinCallResult(name) : recoveredCallResult(direct, null, arguments, expected);
						isRecoveryType(result) && expected != null && !isRecoveryType(expected) ? expected : result;
					}
				} else {
					var direct = recoveredFunctionForCall(name);
					var result = direct == null ? recoveredBuiltinCallResult(name) : recoveredCallResult(direct, null, arguments, expected);
					isRecoveryType(result) && expected != null && !isRecoveryType(expected) ? expected : result;
				}
			case ClosureCall(callee, _, _):
				recoveredCallableResult(recoveredExpressionType(callee), expected);
			case Add(left, right, _): recoveredArithmeticType(left, right, true);
			case Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _): recoveredArithmeticType(left, right, false);
			case BitAnd(left, right, _), BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _),
				UnsignedShiftRight(left, right, _): recoveredIntegerOperationType(left, right);
			case Less(_, _, _), LessEqual(_, _, _), Greater(_, _, _), GreaterEqual(_, _, _), Equal(_, _, _), NotEqual(_, _, _), And(_, _, _), Or(_, _, _):
				TBool;
			case Negate(value, _): recoveredExpressionType(value);
			case Not(_, _): TBool;
			case PostfixIncrement(value, _, _): recoveredExpressionType(value);
			case Conditional(_, whenTrue, whenFalse, _):
				expected != null && !isRecoveryType(expected) ? expected : recoveredCommonType(recoveredExpressionType(whenTrue, expected),
					recoveredExpressionType(whenFalse, expected));
			case BlockExpression(_, result, _):
				var blockResult = recoveredExpressionType(result, expected);
				isRecoveryType(blockResult) && expected != null && !isRecoveryType(expected) ? expected : blockResult;
			case ThrowExpression(_, _): TNever;
			case Cast(value, target, _): target == null ? recoveredExpressionType(value) : recoveredType(target);
			case Index(array, _, _):
				var indexed = indexedValueType(recoveredExpressionBindingType(array));
				indexed == null ? TUnknown : indexed;
			case Range(_, _, _): TRange;
			case ObjectLiteral(fields, _): recoveredObjectLiteralType(fields, expected);
			case ArrayLiteral(values, _): TArray(recoveredArrayElementType(values, indexedValueType(expected)));
			case MapLiteral(entries, _): recoveredMapLiteralType(entries, expected);
			case SwitchExpression(_, cases, fallback, _): recoveredSwitchExpressionType(cases, fallback, expected);
			case ArrayComprehension(keyName, valueName, iterable, _, value, _):
				var iterableType = recoveredExpressionType(iterable),
					bindings:Map<String, CompilerType> = [];
				bindings.set(keyName, recoveredForInKeyType(iterableType, valueName));
				if (valueName != null)
					bindings.set(valueName, recoveredForInValueType(iterableType));
				var element = recoveredComprehensionExpressionType(value, bindings),
					expectedElement = indexedValueType(expected);
				TArray(expectedElement != null && !isRecoveryType(expectedElement) ? expectedElement : element);
			case MapComprehension(keyName, valueName, iterable, _, key, value, _):
				var iterableType = recoveredExpressionType(iterable),
					bindings:Map<String, CompilerType> = [];
				bindings.set(keyName, recoveredForInKeyType(iterableType, valueName));
				if (valueName != null)
					bindings.set(valueName, recoveredForInValueType(iterableType));
				var keyType = recoveredComprehensionExpressionType(key, bindings),
					valueType = recoveredComprehensionExpressionType(value, bindings),
					expectedKey = mapKeyType(expected),
					expectedValue = mapValueType(expected);
				TMap(expectedKey != null && !isRecoveryType(expectedKey) ? expectedKey : keyType,
					expectedValue != null && !isRecoveryType(expectedValue) ? expectedValue : valueType);
			case New(name, _, _): recoveredConstructionType(name, expected);
			case NewGeneric(name, typeArguments, _, _): recoveredGenericConstructionType(name, typeArguments, expected);
			case NewArray(element, _, _): TArray(recoveredType(element));
			case NewMap(key, value, _): TMap(recoveredType(key), recoveredType(value));
			case Lambda(arguments, _, _): recoveredLambdaType(arguments, expected);
			case NativeLayoutQuery(_, _, _, _): TInt;
			default: TUnknown;
		};

	function recoveredBuiltinCallResult(name:String):CompilerType {
		return switch name {
			case "Std.isOfType", "Reflect.isObject": TBool;
			case "Reflect.compare", "Math.ceil", "Std.int", "Std.stdIntFloat": TInt;
			case "Std.stdString", "String.fromCharCode": TString;
			case "haxe.io.Bytes.ofString": TBytes;
			default: recoveredFunctionResult(name);
		};
	}

	function recoveredBuiltinMethodResult(receiver:CompilerType, name:String):Null<CompilerType> {
		return switch receiver {
			case TString:
				switch name {
					case "toLowerCase", "toUpperCase", "substring", "substr", "charAt": TString;
					case "indexOf", "lastIndexOf", "charCodeAt": TInt;
					case "split": TArray(TString);
					default: null;
				};
			case TArray(element):
				switch name {
					case "push", "add", "unshift", "indexOf": TInt;
					case "iterator": TIterator(element);
					case "pop", "shift": element;
					case "resize", "insert", "reverse", "sort": TVoid;
					case "remove", "contains": TBool;
					case "copy", "concat", "slice", "splice": TArray(element);
					case "join": TString;
					default: null;
				};
			case TMap(key, value):
				switch name {
					case "set", "clear": TVoid;
					case "keys": TIterator(key);
					case "values": TIterator(value);
					case "size": TInt;
					case "exists", "remove": TBool;
					case "get": nullableRecoveredValue(value);
					default: null;
				};
			case TIterator(element):
				switch name {
					case "hasNext": TBool;
					case "next": element;
					default: null;
				};
			case TNullable(element): recoveredBuiltinMethodResult(element, name);
			default: null;
		};
	}

	static function nullableRecoveredValue(type:CompilerType):CompilerType
		return switch type {
			case TNullable(_): type;
			default: TNullable(type);
		};

	function recoveredArithmeticType(left:AstExpression, right:AstExpression, add:Bool):CompilerType {
		var leftType = recoveredExpressionType(left),
			rightType = recoveredExpressionType(right);
		if (add && (TypeRelations.equals(leftType, TString) || TypeRelations.equals(rightType, TString)))
			return TString;
		if (leftType == TUnknown || leftType == TError || rightType == TUnknown || rightType == TError)
			return TUnknown;
		if ((TypeRelations.equals(leftType, TInt) && TypeRelations.equals(rightType, TFloat))
			|| (TypeRelations.equals(leftType, TFloat) && TypeRelations.equals(rightType, TInt)))
			return TFloat;
		return TypeRelations.equals(leftType, rightType) && (TypeRelations.equals(leftType, TInt)
			|| TypeRelations.equals(leftType, TInt64) || TypeRelations.equals(leftType, TFloat)) ? leftType : TUnknown;
	}

	function recoveredIntegerOperationType(left:AstExpression, right:AstExpression):CompilerType {
		var leftType = recoveredExpressionType(left),
			rightType = recoveredExpressionType(right);
		if (leftType == TUnknown || leftType == TError || rightType == TUnknown || rightType == TError)
			return TUnknown;
		return TypeRelations.equals(leftType, TInt64) || TypeRelations.equals(rightType, TInt64) ? TInt64 : TInt;
	}

	function recoveredCommonType(left:CompilerType, right:CompilerType):CompilerType {
		if (left == TNever)
			return right;
		if (right == TNever)
			return left;
		if (TypeRelations.equals(left, right))
			return left;
		if (left == TNull)
			switch right {
				case TNullable(_): return right;
				default:
			}
		if (right == TNull)
			switch left {
				case TNullable(_): return left;
				default:
			}
		switch left {
			case TNullable(element):
				var common = switch right {
					case TNullable(other): recoveredCommonType(element, other);
				default: TypeRelations.isReference(right) ? recoveredCommonType(element, right) : TUnknown;
				};
				if (!isRecoveryType(common))
					return TNullable(common);
			default:
		}
		switch right {
			case TNullable(element):
				var common = TypeRelations.isReference(left) ? recoveredCommonType(left, element) : TUnknown;
				if (!isRecoveryType(common))
					return TNullable(common);
			default:
		}
		if (isRecoveryType(left))
			return right;
		if (isRecoveryType(right))
			return left;
		if (left == TNull && TypeRelations.isReference(right))
			return switch right {
				case TNullable(_): right;
				default: TNullable(right);
			};
		if (right == TNull && TypeRelations.isReference(left))
			return switch left {
				case TNullable(_): left;
				default: TNullable(left);
			};
		if ((TypeRelations.equals(left, TInt) && TypeRelations.equals(right, TFloat))
			|| (TypeRelations.equals(left, TFloat) && TypeRelations.equals(right, TInt)))
			return TFloat;
		return TUnknown;
	}

	function recoveredMapLiteralType(entries:Array<compiler.syntax.Ast.AstMapEntry>, ?expected:CompilerType):CompilerType {
		var expectedKey = mapKeyType(expected),
			expectedValue = mapValueType(expected),
			key:Null<CompilerType> = expectedKey,
			value:Null<CompilerType> = expectedValue;
		for (entry in entries) {
			var entryKey = recoveredExpressionType(entry.key, expectedKey),
				entryValue = recoveredExpressionType(entry.value, expectedValue);
			if (key == null)
				key = entryKey;
			else if (isRecoveryType(key) && !isRecoveryType(entryKey))
				key = entryKey;
			else if (!isRecoveryType(key) && !isRecoveryType(entryKey))
				key = recoveredCommonType(key, entryKey);
			if (value == null)
				value = entryValue;
			else if (isRecoveryType(value) && !isRecoveryType(entryValue))
				value = entryValue;
			else if (!isRecoveryType(value) && !isRecoveryType(entryValue))
				value = recoveredCommonType(value, entryValue);
		}
		return TMap(key == null ? TUnknown : key, value == null ? TUnknown : value);
	}

	function recordUnresolved(name:String, span:SourceSpan):Void {
		if (frozen)
			return;
		if (name.length == 0)
			return;
		for (existing in unresolved) {
			checkpoint();
			if (existing.name == name && existing.span.start == span.start && existing.span.end == span.end)
				return;
		}
		var candidates:Array<SemanticSymbolId> = [];
		for (symbol in symbols)
			if (symbol.name == name || sourceName(symbol.name) == name)
				candidates.push(symbol.id);
		if (recoveryCandidates != null)
			for (candidate in recoveryCandidates(name))
				if (candidates.indexOf(candidate) < 0)
					candidates.push(candidate);
		candidates.sort(function(left, right) return Reflect.compare(Std.string(left), Std.string(right)));
		unresolved.push({name: name, span: span, candidates: candidates});
	}

	function recoveredType(type:AstType, ?substitutions:Map<String, CompilerType>):CompilerType {
		return switch type {
			case ErrorType(_): TUnknown;
			case IntType: TInt;
			case BoolType: TBool;
			case FloatType: TFloat;
			case StringType: TString;
			case VoidType: TVoid;
			case ArrayType(element): TArray(recoveredType(element, substitutions));
			case MapType(key, value): TMap(recoveredType(key, substitutions), recoveredType(value, substitutions));
			case NullableType(element): TNullable(recoveredType(element, substitutions));
			case FunctionType(arguments, result): TFunction([for (argument in arguments) recoveredType(argument, substitutions)],
				recoveredType(result, substitutions));
			case AnonymousType(fields):
				var recoveredFields:Array<compiler.types.Type.AnonymousField> = [
					for (field in fields)
						{
							name: field.name,
							type: field.optional ? TNullable(recoveredType(field.type, substitutions)) : recoveredType(field.type, substitutions),
							optional: field.optional
						}
				];
				recoveredFields.sort(function(left, right) return Reflect.compare(left.name, right.name));
				TAnonymous(SemanticSignature.anonymousTypeName(recoveredFields), recoveredFields);
			case NamedType(name):
				var substitution = substitutions == null ? null : substitutions.get(name),
					parameter = currentRecoveredTypeParameters.get(name);
				substitution != null ? substitution : parameter == null ? try {
					var resolved = declarations.resolve(type, null, substitutions);
					isRecoveryType(resolved) ? recoveredExternalType(name, []) : resolved;
				} catch (_:Dynamic) {
					recoveredExternalType(name, []);
				} : parameter;
			case AppliedType(name, arguments):
				try {
					var resolved = declarations.resolve(type, null, substitutions);
					isRecoveryType(resolved) ? recoveredExternalType(name, [for (argument in arguments) recoveredType(argument, substitutions)]) : resolved;
				} catch (_:Dynamic) {
					recoveredExternalType(name, [for (argument in arguments) recoveredType(argument, substitutions)]);
				}
			default: TUnknown;
		};
	}

	function recoveredExternalType(name:String, arguments:Array<CompilerType>):CompilerType {
		// Resolve through the editor's visibility-aware type path first. An
		// explicit import alias such as `import pkg.Foo as F` may resolve to an
		// authoritative symbol through the generic symbol callback, but retaining
		// `F` as the nominal receiver name loses the canonical owner used for
		// member lookup. The type resolver preserves that owner while remaining
		// conservative about ambiguous or invisible declarations.
		if (recoveryResolveType != null) {
			var recovered = recoveryResolveType(name, arguments);
			if (recovered != null && !isRecoveryType(recovered))
				return recovered;
		}
		if (recoveryResolve != null) {
			var id = recoveryResolve(name);
			if (id != null) {
				var identity = Std.string(id);
				if (identity.indexOf(":class:") >= 0)
					return TInstance(compiler.types.Type.NominalKind.Class, name, arguments);
				if (identity.indexOf(":interface:") >= 0)
					return TInstance(compiler.types.Type.NominalKind.Interface, name, arguments);
				if (identity.indexOf(":enum:") >= 0)
					return TInstance(compiler.types.Type.NominalKind.Enum, name, arguments);
			}
		}
		return TUnknown;
	}

	function recoveredFunctionResult(name:String, ?substitutions:Map<String, CompilerType>):CompilerType {
		var fn = recoveredFunctions.get(name);
		if (fn != null)
			return recoveredType(fn.result, substitutions);
		var separator = name.lastIndexOf(".");
		if (separator < 1)
			return TUnknown;
		var method = recoveredMethodWithSubstitutions(name.substring(0, separator), name.substring(separator + 1), [],
			substitutions == null ? [] : substitutions);
		return method == null ? TUnknown : recoveredType(method.method.result, method.substitutions);
	}

	function recoveredCallResult(fn:AstFunction, ?substitutions:Map<String, CompilerType>, arguments:Array<AstExpression>,
			?expected:CompilerType):CompilerType {
		var inferred:Map<String, CompilerType> = [];
		if (substitutions != null)
			for (name => type in substitutions)
				inferred.set(name, type);
		if (fn.typeParameters != null) {
			for (index in 0...arguments.length)
				if (index < fn.arguments.length) {
					var actual = recoveredExpressionType(arguments[index]);
					if (!isRecoveryType(actual))
						inferRecoveredTypeParameters(fn.arguments[index].type, actual, fn.typeParameters, inferred);
				}
			if (expected != null && !isRecoveryType(expected))
				inferRecoveredTypeParameters(fn.result, expected, fn.typeParameters, inferred);
		}
		var result = recoveredExpectedType(fn.result, fn, inferred);
		return isRecoveryType(result) && expected != null && !isRecoveryType(expected) ? expected : result;
	}

	/**
	 * Resolve a generic signature for editor use, retaining an upper-bound when
	 * inference has not received an argument yet. A missing argument in
	 * `bounded(` should still expose the bounded type to completion rather than
	 * degrading immediately to TUnknown.
	 */
	function recoveredExpectedType(type:AstType, fn:AstFunction, substitutions:Map<String, CompilerType>,
		?visiting:Array<String>):CompilerType {
		var active = visiting == null ? [] : visiting;
		return switch type {
			case NamedType(name) if (fn.typeParameters != null && fn.typeParameters.indexOf(name) >= 0):
				var substitution = substitutions.get(name);
				if (substitution != null && !isRecoveryType(substitution))
					substitution;
				else if (active.indexOf(name) >= 0)
					TUnknown;
				else {
					var constraint:Null<AstType> = null;
					if (fn.typeConstraints != null)
						for (candidate in fn.typeConstraints)
							if (candidate.parameter == name) {
								constraint = candidate.type;
								break;
							}
					constraint == null ? TUnknown : recoveredExpectedType(constraint, fn, substitutions, active.concat([name]));
				}
			case ArrayType(element): TArray(recoveredExpectedType(element, fn, substitutions, active));
			case MapType(key, value): TMap(recoveredExpectedType(key, fn, substitutions, active),
				recoveredExpectedType(value, fn, substitutions, active));
			case NullableType(element): TNullable(recoveredExpectedType(element, fn, substitutions, active));
			case FunctionType(arguments, result): TFunction([for (argument in arguments)
				recoveredExpectedType(argument, fn, substitutions, active)], recoveredExpectedType(result, fn, substitutions, active));
			case AppliedType(name, arguments):
				// Resolve the outer nominal type only after recursively replacing
				// generic arguments.  Without this, `Box<T>` remains
				// `Box<TUnknown>` even when T has a useful constraint such as
				// `T:Bound`, which loses expected-type completion information.
				var expectedArguments = [for (argument in arguments)
					recoveredExpectedType(argument, fn, substitutions, active)],
					resolvedSubstitutions:Map<String, CompilerType> = [];
				for (parameter => value in substitutions)
					resolvedSubstitutions.set(parameter, value);
				if (fn.typeParameters != null)
					for (index in 0...arguments.length)
						if (index < expectedArguments.length)
							inferRecoveredTypeParameters(arguments[index], expectedArguments[index], fn.typeParameters, resolvedSubstitutions);
				recoveredType(AppliedType(name, arguments), resolvedSubstitutions);
			case AnonymousType(fields):
				var recoveredFields:Array<compiler.types.Type.AnonymousField> = [
					for (field in fields)
						{
							name: field.name,
							type: field.optional ? TNullable(recoveredExpectedType(field.type, fn, substitutions, active))
								: recoveredExpectedType(field.type, fn, substitutions, active),
							optional: field.optional
						}
				];
				recoveredFields.sort(function(left, right) return Reflect.compare(left.name, right.name));
				TAnonymous(SemanticSignature.anonymousTypeName(recoveredFields), recoveredFields);
			case _: recoveredType(type, substitutions);
		};
	}

	function recoveredFunctionType(name:String, ?substitutions:Map<String, CompilerType>):Null<CompilerType> {
		var fn = recoveredFunctions.get(name);
		if (fn != null)
			return recoveredCallableType(fn, substitutions);
		var separator = name.lastIndexOf(".");
		if (separator < 1)
			return null;
		var method = recoveredMethodWithSubstitutions(name.substring(0, separator), name.substring(separator + 1), [],
			substitutions == null ? [] : substitutions);
		return method == null ? null : recoveredCallableType(method.method, method.substitutions);
	}

	/** Build a callable recovery type, retaining generic constraints as bounds. */
	function recoveredCallableType(fn:AstFunction, ?substitutions:Map<String, CompilerType>):CompilerType {
		var resolved:Map<String, CompilerType> = [];
		if (substitutions != null)
			for (name => type in substitutions)
				resolved.set(name, type);
		return TFunction([for (argument in fn.arguments) recoveredExpectedType(argument.type, fn, resolved)],
			recoveredExpectedType(fn.result, fn, resolved));
	}

	function recoveredCallableResult(type:CompilerType, ?expected:CompilerType):CompilerType {
		var result = functionResultType(type);
		return result == null ? (expected != null && !isRecoveryType(expected) ? expected : TUnknown)
			: isRecoveryType(result) && expected != null && !isRecoveryType(expected) ? expected : result;
	}

	function recoveredMemberType(object:AstExpression, name:String):CompilerType {
		checkpoint();
		var receiverType = recoveredExpressionBindingType(object),
			anonymousType = anonymousMemberType(receiverType, name),
			owner = memberOwner(receiverType),
			substitutions = recoveredTypeSubstitutions(receiverType);
		if (anonymousType != null)
			return anonymousType;
		if (owner == null)
			return TUnknown;
		var fieldType = recoveredFieldType(owner, name, [], substitutions);
		if (fieldType != null)
			return fieldType;
		var functionType = recoveredFunctionType(owner + "." + name, substitutions);
		if (functionType != null)
			return functionType;
		return recoveredFunctionResult(owner + "." + name, substitutions);
	}

	function recoveredFieldType(owner:String, name:String, visiting:Array<String>, ?substitutions:Map<String, CompilerType>):Null<CompilerType> {
		if (visiting.indexOf(owner) >= 0)
			return null;
		var nextVisiting = visiting.copy();
		nextVisiting.push(owner);
		var classDecl = declarations.classes.get(owner);
		if (classDecl != null) {
			for (field in classDecl.fields) {
				checkpoint();
				if (field.name == name && !field.isStatic)
					return field.type == null ? (field.initializer == null ? TUnknown : recoveredExpressionType(field.initializer)) : recoveredType(field.type, substitutions);
			}
			if (classDecl.base != null) {
				var baseType = recoveredType(classDecl.base, substitutions),
					base = memberOwner(baseType);
				if (base != null) {
					var inherited = recoveredFieldType(base, name, nextVisiting, recoveredTypeSubstitutions(baseType));
					if (inherited != null)
						return inherited;
				}
			}
		}
		return null;
	}

	function recoveredMethod(owner:String, name:String, visiting:Array<String>):Null<AstFunction> {
		var resolved = recoveredMethodWithSubstitutions(owner, name, visiting, []);
		return resolved == null ? null : resolved.method;
	}

	function recoveredMethodWithSubstitutions(owner:String, name:String, visiting:Array<String>, substitutions:Map<String, CompilerType>):Null<{
		final method:AstFunction;
		final substitutions:Map<String, CompilerType>;
	}> {
		if (visiting.indexOf(owner) >= 0)
			return null;
		var direct = recoveredFunctions.get(owner + "." + name);
		if (direct != null)
			return {method: direct, substitutions: substitutions};
		var nextVisiting = visiting.copy();
		nextVisiting.push(owner);
		var classDecl = declarations.classes.get(owner);
		if (classDecl != null && classDecl.base != null) {
			var baseType = recoveredType(classDecl.base, substitutions),
				base = memberOwner(baseType);
			if (base != null) {
				var inherited = recoveredMethodWithSubstitutions(base, name, nextVisiting, recoveredTypeSubstitutions(baseType));
				if (inherited != null)
					return inherited;
			}
		}
		if (classDecl != null)
			for (interfaceAstType in classDecl.interfaces) {
				var interfaceType = recoveredType(interfaceAstType, substitutions),
					interfaceOwner = memberOwner(interfaceType);
				if (interfaceOwner != null) {
					var inherited = recoveredMethodWithSubstitutions(interfaceOwner, name, nextVisiting,
						recoveredTypeSubstitutions(interfaceType));
					if (inherited != null)
						return inherited;
				}
			}
		var interfaceDecl = declarations.interfaces.get(owner);
		if (interfaceDecl != null)
			for (baseType in interfaceDecl.bases) {
				var resolvedBaseType = recoveredType(baseType, substitutions),
					base = memberOwner(resolvedBaseType);
				if (base != null) {
					var inherited = recoveredMethodWithSubstitutions(base, name, nextVisiting, recoveredTypeSubstitutions(resolvedBaseType));
					if (inherited != null)
						return inherited;
				}
			}
		return null;
	}

	function recoveredFunction(name:String):Null<AstFunction> {
		var direct = recoveredFunctions.get(name);
		if (direct != null)
			return direct;
		var separator = name.lastIndexOf(".");
		return separator < 1 ? null : recoveredMethod(name.substring(0, separator), name.substring(separator + 1), []);
	}

	function recoveredArrayElementType(values:Array<AstExpression>, ?expectedElement:CompilerType):CompilerType {
		if (expectedElement != null && !isRecoveryType(expectedElement))
			return expectedElement;
		var result:Null<CompilerType> = null;
		for (value in values) {
			var type = recoveredExpressionType(value);
			result = result == null ? type : recoveredCommonType(result, type);
		}
		return result == null ? TUnknown : result;
	}

	function recoveredObjectLiteralType(fields:Array<compiler.syntax.Ast.AstObjectField>, ?expected:CompilerType):CompilerType {
		var inferred:Array<compiler.types.Type.AnonymousField> = [];
		for (field in fields) {
			var fieldType = expectedFieldType(expected, field.name),
				actual = recoveredExpressionType(field.value, fieldType);
			if (fieldType == null || isRecoveryType(fieldType) && !isRecoveryType(actual))
				fieldType = actual;
			inferred.push({name: field.name, type: fieldType, optional: false});
		}
		inferred.sort(function(left, right) return Reflect.compare(left.name, right.name));
		return switch expected {
			case TAnonymous(_, _), TNullable(TAnonymous(_, _)): expected;
			default: TAnonymous(SemanticSignature.anonymousTypeName(inferred), inferred);
		};
	}

	function recoveredForInKeyType(type:CompilerType, valueName:Null<String>):CompilerType
		return switch type {
			case TArray(element), TIterator(element): element;
			case TRange: TInt;
			case TMap(key, value): valueName == null ? value : key;
			case TNullable(element): recoveredForInKeyType(element, valueName);
			default: TUnknown;
		};

	function recoveredForInValueType(type:CompilerType):CompilerType
		return switch type {
			case TMap(_, value): value;
			case TNullable(element): recoveredForInValueType(element);
			default: TUnknown;
		};

	function recoveredComprehensionExpressionType(expression:AstExpression, bindings:Map<String, CompilerType>):CompilerType
		return switch expression {
			case Variable(name, _) if (bindings.exists(name)): bindings.get(name);
			case Variable(name, span) if (name.indexOf(".") > 0):
				var parts = name.split("."), current:AstExpression = Variable(parts[0], span);
				for (index in 1...parts.length)
					current = Member(current, parts[index], span);
				recoveredComprehensionExpressionType(current, bindings);
			case Member(object, name, _):
				var memberType = recoveredComprehensionMemberType(object, name, bindings);
				memberType;
			case MethodCall(object, name, arguments, _):
				var receiverType = recoveredComprehensionExpressionType(object, bindings),
					builtinResult = recoveredBuiltinMethodResult(receiverType, name),
					anonymousMember = anonymousMemberType(receiverType, name),
					owner = memberOwner(receiverType),
					method = owner == null ? null : recoveredMethodWithSubstitutions(owner, name, [], recoveredTypeSubstitutions(receiverType));
				if (builtinResult != null)
					builtinResult;
				else if (anonymousMember != null)
					recoveredCallableResult(anonymousMember);
				else if (method != null)
					recoveredCallResult(method.method, method.substitutions, arguments);
				else
					TUnknown;
			case Call(name, arguments, span):
				var separator = name.lastIndexOf(".");
				if (separator > 0) {
					var receiverName = name.substring(0, separator),
						memberName = name.substring(separator + 1),
						receiverType = recoveredComprehensionExpressionType(Variable(receiverName, span), bindings),
						builtinResult = recoveredBuiltinMethodResult(receiverType, memberName),
						owner = memberOwner(receiverType),
						method = owner == null ? null : recoveredMethodWithSubstitutions(owner, memberName, [], recoveredTypeSubstitutions(receiverType));
					if (builtinResult != null)
						builtinResult;
					else if (method != null)
						recoveredCallResult(method.method, method.substitutions, arguments);
					else
						TUnknown;
				} else
					recoveredExpressionType(expression);
			case Index(array, _, _):
				var indexed = indexedValueType(recoveredComprehensionExpressionType(array, bindings));
				indexed == null ? TUnknown : indexed;
			case Conditional(_, whenTrue, whenFalse, _):
				recoveredCommonType(recoveredComprehensionExpressionType(whenTrue, bindings),
					recoveredComprehensionExpressionType(whenFalse, bindings));
			case Cast(value, target, _):
				target == null ? recoveredComprehensionExpressionType(value, bindings) : recoveredType(target);
			case ArrayComprehension(keyName, valueName, iterable, _, value, _):
				var iterableType = recoveredComprehensionExpressionType(iterable, bindings),
					innerBindings:Map<String, CompilerType> = [];
				innerBindings.set(keyName, recoveredForInKeyType(iterableType, valueName));
				if (valueName != null)
					innerBindings.set(valueName, recoveredForInValueType(iterableType));
				TArray(recoveredComprehensionExpressionType(value, innerBindings));
			case MapComprehension(keyName, valueName, iterable, _, key, value, _):
				var iterableType = recoveredComprehensionExpressionType(iterable, bindings),
					innerBindings:Map<String, CompilerType> = [];
				innerBindings.set(keyName, recoveredForInKeyType(iterableType, valueName));
				if (valueName != null)
					innerBindings.set(valueName, recoveredForInValueType(iterableType));
				TMap(recoveredComprehensionExpressionType(key, innerBindings), recoveredComprehensionExpressionType(value, innerBindings));
			default: recoveredExpressionType(expression);
			};

	function recoveredComprehensionMemberType(object:AstExpression, name:String, bindings:Map<String, CompilerType>):CompilerType {
		var receiverType = recoveredComprehensionExpressionType(object, bindings),
			anonymousType = anonymousMemberType(receiverType, name),
			owner = memberOwner(receiverType),
			substitutions = recoveredTypeSubstitutions(receiverType);
		if (anonymousType != null)
			return anonymousType;
		if (owner == null)
			return TUnknown;
		var fieldType = recoveredFieldType(owner, name, [], substitutions);
		if (fieldType != null)
			return fieldType;
		var functionType = recoveredFunctionType(owner + "." + name, substitutions);
		return functionType == null ? TUnknown : functionType;
	}

	function indexRecoveredPatternBindings(functionKey:String, pattern:AstExpression, expected:CompilerType,
			scope:SourceSpan, depth:Int):Void {
		var recovered = recoveredEnumPattern(pattern, expected);
		if (recovered == null)
			return;
		switch pattern {
			case Call(_, arguments, _):
				for (index in 0...arguments.length)
					if (index < recovered.params.length)
						indexRecoveredPatternBinding(functionKey, arguments[index], recoveredType(recovered.params[index].type,
							recovered.substitutions), scope, depth);
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_), Unreachable(_), ErrorExpression(_),
				Variable(_, _), Member(_, _, _), Add(_, _, _), Sub(_, _, _), Mul(_, _, _), Div(_, _, _), Mod(_, _, _), BitAnd(_, _, _), BitXor(_, _, _),
				BitOr(_, _, _), ShiftLeft(_, _, _), ShiftRight(_, _, _), UnsignedShiftRight(_, _, _), Negate(_, _), Less(_, _, _), LessEqual(_, _, _),
				Greater(_, _, _), GreaterEqual(_, _, _), Equal(_, _, _), NotEqual(_, _, _), Not(_, _), And(_, _, _), Or(_, _, _), Conditional(_, _, _, _),
				BlockExpression(_, _, _), ThrowExpression(_, _), Cast(_, _, _), SwitchExpression(_, _, _, _), ObjectLiteral(_, _), MapLiteral(_, _),
				ArrayComprehension(_, _, _, _, _, _), MapComprehension(_, _, _, _, _, _, _), Range(_, _, _), NativeLayoutQuery(_, _, _, _), ClosureCall(_, _, _),
				MethodCall(_, _, _, _), New(_, _, _), NewGeneric(_, _, _, _), NewArray(_, _, _), NewMap(_, _, _), Index(_, _, _), PostfixIncrement(_, _, _),
				Lambda(_, _, _), ArrayLiteral(_, _):
		}
	}

	function indexRecoveredPatternBinding(functionKey:String, pattern:AstExpression, type:CompilerType,
			scope:SourceSpan, depth:Int):Void {
		switch pattern {
			case Variable(name, span) if (name != "_" && name.indexOf(".") < 0):
				addRecoveredLocal(functionKey, name, type, span, scope, depth);
			case ArrayLiteral(values, _):
				switch type {
					case TArray(element):
						for (value in values)
							indexRecoveredPatternBinding(functionKey, value, element, scope, depth);
					default:
				}
			case Variable(_, _), IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_), Unreachable(_),
				ErrorExpression(_), Member(_, _, _), Add(_, _, _), Sub(_, _, _), Mul(_, _, _), Div(_, _, _), Mod(_, _, _), BitAnd(_, _, _), BitXor(_, _, _),
				BitOr(_, _, _), ShiftLeft(_, _, _), ShiftRight(_, _, _), UnsignedShiftRight(_, _, _), Negate(_, _), Less(_, _, _), LessEqual(_, _, _),
				Greater(_, _, _), GreaterEqual(_, _, _), Equal(_, _, _), NotEqual(_, _, _), Not(_, _), And(_, _, _), Or(_, _, _), Conditional(_, _, _, _),
				BlockExpression(_, _, _), ThrowExpression(_, _), Cast(_, _, _), SwitchExpression(_, _, _, _), ObjectLiteral(_, _), MapLiteral(_, _),
				ArrayComprehension(_, _, _, _, _, _), MapComprehension(_, _, _, _, _, _, _), Range(_, _, _), Call(_, _, _), NativeLayoutQuery(_, _, _, _),
				ClosureCall(_, _, _), MethodCall(_, _, _, _), New(_, _, _), NewGeneric(_, _, _, _), NewArray(_, _, _), NewMap(_, _, _), Index(_, _, _),
				PostfixIncrement(_, _, _), Lambda(_, _, _):
		}
	}

	function recoveredEnumPattern(pattern:AstExpression, expected:CompilerType):Null<RecoveredEnumPattern> {
		return switch pattern {
			case Call(name, _, _):
				var separator = name.lastIndexOf("."),
					caseName = separator < 0 ? name : name.substring(separator + 1),
					enumName:Null<String> = separator < 0 ? recoveredEnumName(expected) : name.substring(0, separator),
					declaration:Null<compiler.syntax.Ast.AstEnum> = enumName == null ? null : declarations.enums.get(enumName);
				if (declaration == null && separator < 0) {
					var match:Null<compiler.syntax.Ast.AstEnum> = null;
					for (candidate in declarations.enums)
						for (candidateCase in candidate.cases)
							if (candidateCase.name == caseName) {
								if (match != null)
									return null;
								match = candidate;
							}
					declaration = match;
				}
				if (declaration == null)
					null;
				else {
					for (candidateCase in declaration.cases)
						if (candidateCase.name == caseName)
							return {
								params: candidateCase.params,
								substitutions: recoveredTypeSubstitutions(expected)
							};
					null;
				}
			default: null;
		};
	}

	function recoveredEnumName(type:CompilerType):Null<String>
		return switch type {
			case TInstance(compiler.types.Type.NominalKind.Enum, name, _): name;
			case TNullable(element): recoveredEnumName(element);
			default: null;
		};

	function indexRecoveredCallArguments(arguments:Array<AstExpression>, fn:Null<AstFunction>, ?substitutions:Map<String, CompilerType>,
			?explicitExpected:Array<CompilerType>, ?functionKey:String, ?resultExpected:CompilerType):Void {
		var inferredSubstitutions:Map<String, CompilerType> = [];
		if (substitutions != null)
			for (name => type in substitutions)
				inferredSubstitutions.set(name, type);
		if (fn != null && fn.typeParameters != null) {
			for (index in 0...arguments.length)
				if (index < fn.arguments.length) {
					var actual = recoveredExpressionType(arguments[index]);
					if (!isRecoveryType(actual))
						inferRecoveredTypeParameters(fn.arguments[index].type, actual, fn.typeParameters, inferredSubstitutions);
				}
			if (resultExpected != null && !isRecoveryType(resultExpected))
				inferRecoveredTypeParameters(fn.result, resultExpected, fn.typeParameters, inferredSubstitutions);
		}
		for (index in 0...arguments.length) {
			checkpoint();
			var argument = arguments[index];
			var expected = explicitExpected != null && index < explicitExpected.length ? explicitExpected[index]
				: fn == null || index >= fn.arguments.length ? null : recoveredExpectedType(fn.arguments[index].type, fn, inferredSubstitutions);
			indexRecoveredExpression(argument, expected, functionKey);
		}
	}

	/** Infer only concrete generic arguments that are already evident in source. */
	function inferRecoveredTypeParameters(pattern:AstType, actual:CompilerType, parameters:Array<String>,
			substitutions:Map<String, CompilerType>):Void {
		switch pattern {
			case NamedType(name) if (parameters.indexOf(name) >= 0):
				var previous = substitutions.get(name);
				if (previous == null || isRecoveryType(previous))
					substitutions.set(name, actual);
			case ArrayType(element):
				switch actual {
					case TArray(value): inferRecoveredTypeParameters(element, value, parameters, substitutions);
					case TIterator(value): inferRecoveredTypeParameters(element, value, parameters, substitutions);
					case _:
				}
			case MapType(key, value):
				switch actual {
					case TMap(actualKey, actualValue):
						inferRecoveredTypeParameters(key, actualKey, parameters, substitutions);
						inferRecoveredTypeParameters(value, actualValue, parameters, substitutions);
					case _:
				}
			case NullableType(element):
				switch actual {
					case TNullable(value): inferRecoveredTypeParameters(element, value, parameters, substitutions);
					case _: inferRecoveredTypeParameters(element, actual, parameters, substitutions);
				}
			case FunctionType(arguments, result):
				switch actual {
					case TFunction(actualArguments, actualResult):
						for (index in 0...arguments.length)
							if (index < actualArguments.length)
								inferRecoveredTypeParameters(arguments[index], actualArguments[index], parameters, substitutions);
						inferRecoveredTypeParameters(result, actualResult, parameters, substitutions);
					case _:
				}
			case AppliedType(name, arguments):
				var actualArguments = recoveredNominalArguments(actual, name);
				if (actualArguments != null)
					for (index in 0...arguments.length)
						if (index < actualArguments.length)
							inferRecoveredTypeParameters(arguments[index], actualArguments[index], parameters, substitutions);
			case _:
			}
	}

	function recoveredNominalArguments(type:CompilerType, name:String):Null<Array<CompilerType>>
		return switch type {
			case TInstance(_, declaration, arguments) if (sourceName(declaration) == sourceName(name) || declaration == name): arguments;
			case TAbstract(declaration, arguments, _) if (sourceName(declaration) == sourceName(name) || declaration == name): arguments;
			case _: null;
		};

	function recoveredBuiltinCallArguments(name:String):Null<Array<CompilerType>> {
		return switch name {
			case "Std.isOfType": [TDynamic, TUnknown];
			case "Reflect.compare": [TUnknown, TUnknown];
			case "Reflect.isObject": [TDynamic];
			case "Math.ceil": [TFloat];
			case "haxe.io.Bytes.ofString": [TString, TUnknown];
			case "Std.int", "Std.stdIntFloat": [TUnknown];
			case "Std.stdString": [TDynamic];
			case "String.__alloc__": [THlBytes, TInt];
			case "String.fromCharCode": [TInt];
			case "RuntimeData.address", "runtime.RuntimeData.address": [TArray(TString)];
			case "RuntimeData.loadI32", "runtime.RuntimeData.loadI32": [TInt];
			default: null;
		};
	}

	function recoveredBuiltinMethodArguments(receiver:CompilerType, name:String):Null<Array<CompilerType>> {
		return switch receiver {
			case TString:
				switch name {
					case "toLowerCase", "toUpperCase": [];
					case "indexOf", "lastIndexOf": [TString, TInt];
					case "substring", "substr": [TInt, TInt];
					case "charCodeAt", "charAt": [TInt];
					case "split": [TString];
					default: null;
				};
			case TArray(element):
				switch name {
					case "push", "add", "unshift", "remove", "indexOf", "contains": [element];
					case "iterator", "pop", "shift", "reverse", "copy": [];
					case "resize": [TInt];
					case "insert": [TInt, element];
					case "concat": [TArray(element)];
					case "slice": [TInt, TInt];
					case "splice": [TInt, TInt];
					case "sort": [TFunction([element, element], TInt)];
					case "join": [TString];
					default: null;
				};
			case TMap(key, value):
				switch name {
					case "set": [key, value];
					case "keys", "values", "clear", "size": [];
					case "exists", "remove", "get": [key];
					default: null;
				};
			case TIterator(_):
				switch name {
					case "hasNext", "next": [];
					default: null;
				};
			case TNullable(element): recoveredBuiltinMethodArguments(element, name);
			default: null;
		};
	}

	function recoveredLocalType(name:String, span:SourceSpan):Null<CompilerType> {
		var found:Null<SemanticCompletionLocal> = null;
		for (local in completionLocals)
			if (local.name == name
				&& local.declaration.start <= span.start
				&& span.start >= local.scope.start
				&& span.end <= local.scope.end
				&& (found == null
					|| local.depth > found.depth
					|| local.depth == found.depth
					&& local.declaration.start > found.declaration.start))
				found = local;
		return found == null ? null : found.type;
	}

	function indexedValueType(type:Null<CompilerType>):Null<CompilerType>
		return switch type {
			case TArray(element), TIterator(element): element;
			case TMap(_, value): value;
			case TNullable(element): indexedValueType(element);
			default: null;
		};

	function mapKeyType(type:Null<CompilerType>):Null<CompilerType>
		return switch type {
			case TMap(key, _): key;
			case TNullable(element): mapKeyType(element);
			default: null;
		};

	function mapValueType(type:Null<CompilerType>):Null<CompilerType>
		return switch type {
			case TMap(_, value): value;
			case TNullable(element): mapValueType(element);
			default: null;
		};

	function expectedFieldType(type:Null<CompilerType>, name:String):Null<CompilerType>
		return switch type {
			case TAnonymous(_, fields):
				for (field in fields)
					if (field.name == name)
						return field.type;
				null;
			case TNullable(element): expectedFieldType(element, name);
			default: null;
		};

	function anonymousMemberType(type:CompilerType, name:String):Null<CompilerType>
		return switch type {
			case TAnonymous(_, fields):
				for (field in fields)
					if (field.name == name)
						return field.type;
				null;
			case TNullable(element): anonymousMemberType(element, name);
			default: null;
		};

	function anonymousFunctionArguments(type:Null<CompilerType>):Null<Array<CompilerType>>
		return switch type {
			case TFunction(arguments, _): arguments;
			case TNullable(element): anonymousFunctionArguments(element);
			default: null;
		};

	function expectedFunctionArgument(type:Null<CompilerType>, index:Int):Null<CompilerType>
		return switch type {
			case TFunction(arguments, _): index < arguments.length ? arguments[index] : null;
			case TNullable(element): expectedFunctionArgument(element, index);
			default: null;
		};

	function functionResultType(type:Null<CompilerType>):Null<CompilerType>
		return switch type {
			case TFunction(_, result): result;
			case TNullable(element): functionResultType(element);
			default: null;
		};

	function recoveredFunctionForCall(name:String):Null<AstFunction> {
		var fn = recoveredFunction(name);
		return fn == null ? recoveredFunction(name + ".new") : fn;
	}

	/** Index a typed field initializer under its field declaration identity. */
	public function indexTypedInitializer(owner:String, expression:TypedExpression, resolve:String->Null<SemanticSymbolId>,
			resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>):Void {
		ensureMutable();
		currentCaller = resolve(owner);
		currentCallerName = owner;
		currentDependencyKind = SemanticDependencyKind.Initializer;
		var synthetic:TypedFunction = {
			name: owner,
			owner: null,
			isStatic: true,
			isConstructor: false,
			arguments: [],
			result: expression.type,
			statements: [],
			cells: [],
			cellCaptures: [],
			span: expression.span
		};
		indexExpression(synthetic, expression, resolve, resolveEnumCase);
		currentCaller = null;
		currentCallerName = null;
		currentDependencyKind = SemanticDependencyKind.Body;
	}

	public function indexTypeReferences(resolve:String->Null<SemanticSymbolId>, ?token:CancellationToken):Void {
		ensureMutable();
		var started = Sys.time();
		if (token != null)
			token.check();
		cancellation = token;
		for (index in 0...tokens.length) {
			checkpoint();
			var token = tokens[index];
			if (token.kind != TokenKind.Identifier || !isTypeReferenceToken(index))
				continue;
			var name = qualifiedTokenName(index), id = typeParameterAt(token.span.start, token.text);
			if (id == null)
				id = resolve(name);
			if (id == null)
				id = resolve(token.text);
			if (id != null)
				bind(id, token.span);
			else
				recordUnresolved(name, token.span);
		}
		bindings.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
		checkpoint();
		cancellation = null;
		indexingMs += (Sys.time() - started) * 1000.0;
	}

	public function completionContext(position:Int, ?qualifier:String, ?token:CancellationToken):SemanticCompletionContext {
		return SemanticCompletionQuery.build({
			locals: completionLocals,
			typeParameters: recoveredTypeParameterScopes,
			receivers: functionReceivers,
			expectedTypes: completionTypes,
			classBases: recoveredClassBases,
			declarations: declarations,
			tokens: tokens,
			qualifierType: function(qualifier:String, position:Int) return recoveredQualifierType(qualifier, position)
		}, position, qualifier, token);
	}

	/** Resolve a dotted receiver such as `root.child` for member completion. */
	function recoveredQualifierType(qualifier:String, position:Int):Null<CompilerType> {
		var parts = qualifier.split(".");
		if (parts.length == 0 || parts[0].length == 0 || source == null)
			return null;
		var bounded = position < 0 ? 0 : position > source.bytes.length ? source.bytes.length : position,
			span = source.span(bounded, bounded),
			expression:AstExpression = Variable(parts[0], span);
		for (index in 1...parts.length)
			expression = Member(expression, parts[index], span);
		var type = recoveredExpressionBindingType(expression);
		return isRecoveryType(type) ? null : type;
	}

	function addCompletionLocal(identity:String, type:CompilerType, declaration:SourceSpan, scope:SourceSpan, depth:Int):Void {
		var token = declarationToken(tokens, declaration, sourceLocalName(identity));
		if (token == null)
			return;
		scope = currentSpan(scope);
		var name = sourceLocalName(identity);
		for (index in 0...completionLocals.length) {
			var existing = completionLocals[index];
			if (existing.name == name
				&& existing.declaration.start == token.span.start
				&& existing.declaration.end == token.span.end
				&& existing.scope.start == scope.start
				&& existing.scope.end == scope.end
				&& existing.depth == depth) {
				if (isRecoveryType(existing.type) && !isRecoveryType(type))
					completionLocals[index] = {
						name: name,
						type: type,
						declaration: token.span,
						scope: scope,
						depth: depth
					};
				return;
			}
		}
		completionLocals.push({
			name: name,
			type: type,
			declaration: token.span,
			scope: scope,
			depth: depth
		});
	}

	/** Rebind spans from a safely reused typed body to this index's source. */
	function currentSpan(span:SourceSpan):SourceSpan
		return source == null || span.file == source ? span : source.span(span.start, span.end);

	static function isRecoveryType(type:CompilerType):Bool
		return TypeRelations.containsRecovery(type);

	function indexCompletionLocals(statements:Array<TypedStatement>, scope:SourceSpan, depth:Int):Void {
		for (statement in statements) {
			checkpoint();
			switch statement {
				case TDeclare(name, type, span):
					addCompletionLocal(name, type, span, scope, depth);
				case TVar(name, value, span):
					addCompletionLocal(name, value.type, span, scope, depth);
				case TIf(_, yes, no, span):
					indexCompletionLocals(yes, span, depth + 1);
					indexCompletionLocals(no, span, depth + 1);
				case TWhile(_, body, span), TDoWhile(body, _, span):
					indexCompletionLocals(body, span, depth + 1);
				case TForIn(name, valueName, iterable, body, span):
					var keyType = recoveredForInKeyType(iterable.type, valueName);
					addCompletionLocal(name, keyType, span, span, depth + 1);
					if (valueName != null) {
						var valueType = recoveredForInValueType(iterable.type);
						addCompletionLocal(valueName, valueType, span, span, depth + 1);
					}
					indexCompletionLocals(body, span, depth + 1);
				case TTry(body, catches, span):
					indexCompletionLocals(body, span, depth + 1);
					for (caught in catches) {
						addCompletionLocal(caught.name, caught.type, caught.span, caught.span, depth + 1);
						indexCompletionLocals(caught.statements, caught.span, depth + 1);
					}
				case TSwitch(_, cases, fallback, _, span):
					for (item in cases) {
						if (item.subjectBinding != null)
							addCompletionLocal(item.subjectBinding, item.value.type, item.span, item.span, depth + 1);
						for (binding in item.bindings)
							addCompletionLocal(binding.name, binding.type, item.span, item.span, depth + 1);
						indexCompletionLocals(item.statements, item.span, depth + 1);
					}
					indexCompletionLocals(fallback, span, depth + 1);
				default:
			}
		}
	}

	function declareLocals(fn:TypedFunction, statements:Array<TypedStatement>):Void {
		TypedAstChildren.statements(statements,
			function(statement) switch statement {
				case TDeclare(name, type, span):
					declareLocal(fn, name, span, type);
				case TVar(name, value, span):
					declareLocal(fn, name, span, value.type);
				case TForIn(name, valueName, iterable, _, _):
					declareLocal(fn, name, iterable.span, recoveredForInKeyType(iterable.type, valueName));
					if (valueName != null)
						declareLocal(fn, valueName, iterable.span, recoveredForInValueType(iterable.type));
				case TTry(_, catches, _):
					for (caught in catches)
						declareLocal(fn, caught.name, caught.span, caught.type);
				case TSwitch(_, cases, _, _, _):
					for (item in cases) {
						if (item.subjectBinding != null)
							declareLocal(fn, item.subjectBinding, item.span, item.value.type);
						for (binding in item.bindings)
							declareLocal(fn, binding.name, item.span, binding.type);
					}
				default:
			},
			function(expression) switch expression.expression {
				case TSwitchExpression(_, cases, _):
					for (item in cases) {
						if (item.subjectBinding != null)
							declareLocal(fn, item.subjectBinding, item.span, item.value.type);
						for (binding in item.bindings)
							declareLocal(fn, binding.name, item.span, binding.type);
					}
				default:
			});
	}

	function declareLocal(fn:TypedFunction, identity:String, within:SourceSpan, ?type:CompilerType):Void {
		if (identity == "this")
			return;
		var id = localId(fn, identity);
		if (!symbols.exists(id)) {
			var token = declarationToken(tokens, within, sourceLocalName(identity));
			if (token == null)
				return;
			symbols.set(id, {
				id: id,
				name: sourceLocalName(identity),
				kind: DeclarationKind.Member,
				declaration: token.span
			});
			bind(id, token.span);
		}
		if (type != null && !isRecoveryType(type))
			declarationTypes.set(id, type);
	}

	function indexStatements(fn:TypedFunction, statements:Array<TypedStatement>, resolve:String->Null<SemanticSymbolId>,
			resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>):Void {
		TypedAstChildren.statements(statements,
			function(statement) switch statement {
				case TAssign(identity, _, span), TCellAssign(identity, _, _, span), TCellCapturedAssign(identity, _, _, span):
					bindLocalUse(fn, identity, span);
				case TIncrement(identity, _, span), TCellIncrement(identity, _, _, _, span), TCellCapturedIncrement(identity, _, _, _, span):
					bindLocalUse(fn, identity, span);
				case TFieldAssign(object, name, _, span):
					bindMember(resolve, object.type, name, span);
				case TStaticFieldAssign(owner, name, _, span):
					bindNamed(resolve, owner + "." + name, span);
				case TSwitch(_, cases, _, _, _):
					for (item in cases)
						bindEnumCase(resolveEnumCase, item.enumName, item.constructorIndex, item.span);
				default:
			},
			function(expression) indexExpressionNode(fn, expression, resolve, resolveEnumCase));
	}

	function indexExpression(fn:TypedFunction, expression:TypedExpression, resolve:String->Null<SemanticSymbolId>,
			resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>):Void {
		TypedAstChildren.expression(expression,
			function(statement) switch statement {
				case TAssign(identity, _, span), TCellAssign(identity, _, _, span), TCellCapturedAssign(identity, _, _, span):
					bindLocalUse(fn, identity, span);
				case TIncrement(identity, _, span), TCellIncrement(identity, _, _, _, span), TCellCapturedIncrement(identity, _, _, _, span):
					bindLocalUse(fn, identity, span);
				case TFieldAssign(object, name, _, span):
					bindMember(resolve, object.type, name, span);
				case TStaticFieldAssign(owner, name, _, span):
					bindNamed(resolve, owner + "." + name, span);
				case TSwitch(_, cases, _, _, _):
					for (item in cases)
						bindEnumCase(resolveEnumCase, item.enumName, item.constructorIndex, item.span);
				default:
			},
			function(child) indexExpressionNode(fn, child, resolve, resolveEnumCase));
	}

	function indexExpressionNode(fn:TypedFunction, expression:TypedExpression, resolve:String->Null<SemanticSymbolId>,
			resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>):Void {
		completionTypes.push({span: currentSpan(expression.span), type: expression.type});
		switch expression.expression {
			case TLocal(identity), TCellLocal(identity, _), TCaptured(identity), TCellCaptured(identity, _),
				TPostfixLocal(identity, _), TPostfixCellLocal(identity, _, _), TPostfixCellCaptured(identity, _, _):
				var id = localId(fn, identity);
				var token = referenceToken(tokens, expression.span, sourceLocalName(identity));
				if (symbols.exists(id) && token != null)
					bind(id, token.span);
			case TField(object, name):
				bindMember(resolve, object.type, name, expression.span);
			case TPostfixField(object, name, _):
				bindMember(resolve, object.type, name, expression.span);
			case TMethodCall(object, method, arguments):
				var methodName = memberName(method),
					callee = bindMember(resolve, object.type, methodName, expression.span);
				if (callee == null && method != methodName)
					callee = bindNamed(resolve, method, expression.span);
				addCall(callee, expression.span, methodName);
			case TCall(name, arguments), TCNativeCall(name, arguments):
				var shadowed = localBindingAt(fn, name, expression.span.start);
				if (shadowed != null) {
					bind(shadowed, referenceToken(tokens, expression.span, sourceLocalName(name)) == null ? expression.span
						: referenceToken(tokens, expression.span, sourceLocalName(name)).span);
				} else
					addCall(bindNamed(resolve, name, expression.span), expression.span, name);
			case TFunctionRef(name):
				bindNamed(resolve, name, expression.span);
			case TMethodRef(object, name):
				var methodName = memberName(name),
					callee = bindMember(resolve, object.type, methodName, expression.span);
				if (callee == null && name != methodName)
					bindNamed(resolve, name, expression.span);
			case TClassRef(name):
				bindNamed(resolve, name, expression.span);
			case TStaticField(owner, name):
				bindNamed(resolve, owner + "." + name, expression.span);
			case TPostfixStaticField(owner, name, _):
				bindNamed(resolve, owner + "." + name, expression.span);
			case TNew(name, arguments, _):
				addCall(bindNamed(resolve, name, expression.span), expression.span, name);
			case TEnumLiteral(name, index):
				bindEnumCase(resolveEnumCase, name, index, expression.span);
			case TEnumConstruct(name, index, arguments):
				bindEnumCase(resolveEnumCase, name, index, expression.span);
			case TSwitchExpression(value, cases, fallback):
				for (item in cases) {
					bindEnumCase(resolveEnumCase, item.enumName, item.constructorIndex, item.value.span);
				}
			case TSuperCall(owner, arguments):
				bindNamed(resolve, owner, expression.span);
			default:
		}
	}

	function addCall(callee:Null<SemanticSymbolId>, expression:SourceSpan, name:String):Void {
		if (frozen)
			return;
		if (currentCaller == null || callee == null)
			return;
		var token = referenceToken(tokens, expression, sourceName(name));
		var span = token == null ? currentSpan(expression) : token.span;
		for (edge in callEdges)
			if (edge.caller == currentCaller && edge.callee == callee && edge.span.start == span.start && edge.span.end == span.end)
				return;
		callEdges.push({caller: currentCaller, callee: callee, span: span});
	}

	function indexCallTokens(fn:TypedFunction, caller:Null<SemanticSymbolId>, resolve:String->Null<SemanticSymbolId>):Void {
		if (caller == null)
			return;
		var declaration = declarationToken(tokens, fn.span, sourceName(fn.name));
		var index = tokenIndexAtOrAfter(tokens, fn.span.start);
		while (index < tokens.length) {
			var token = tokens[index++];
			if (token.span.start > fn.span.end)
				break;
			if (token.span.end > fn.span.end
				|| token.kind != TokenKind.Identifier
				|| index > 1 && tokens[index - 2].kind == TokenKind.Dot
				|| index >= tokens.length
				|| tokens[index].kind != TokenKind.LeftParen
				|| symbolIdAtForConstruction(token.span.start) != null
				|| declaration != null
				&& token.span.start == declaration.span.start)
				continue;
			var callee = resolve(token.text);
			if (callee != null) {
				currentCaller = caller;
				addCall(callee, token.span, token.text);
			}
		}
	}

	function symbolIdAtForConstruction(position:Int):Null<SemanticSymbolId> {
		var selected:Null<PositionBinding> = null;
		for (binding in bindings) {
			if (position < binding.span.start || position > binding.span.end)
				continue;
			var width = binding.span.end - binding.span.start,
				selectedWidth = selected == null ? 0x3fffffff : selected.span.end - selected.span.start;
			if (selected == null || width < selectedWidth
				|| width == selectedWidth && binding.span.start > selected.span.start)
				selected = binding;
		}
		return selected == null ? null : selected.symbol;
	}

	function bind(id:SemanticSymbolId, span:SourceSpan):Void {
		if (frozen)
			return;
		span = currentSpan(span);
		checkpoint();
		var locations = references.get(id);
		var keys = referenceKeys.get(id);
		if (locations == null) {
			references.set(id, locations = []);
			referenceKeys.set(id, keys = []);
		}
		var key = span.file.path + ":" + span.start + ":" + span.end;
		if (keys.exists(key))
			return;
		keys.set(key, true);
		bindings.push({span: span, symbol: id});
		locations.push(span);
	}

	inline function checkpoint():Void {
		if (frozen)
			return;
		checkpointCount++;
		if ((checkpointCount & 127) == 0 && cancellation != null)
			cancellation.check();
	}

	function isTypeReferenceToken(index:Int):Bool {
		if (index <= 0)
			return false;
		var previous = tokens[index - 1].kind;
		if (previous == TokenKind.Colon
			|| previous == TokenKind.Extends
			|| previous == TokenKind.Implements
			|| previous == TokenKind.Less)
			return true;
		if (previous == TokenKind.Assign)
			return precededBy(TokenKind.Typedef, index);
		if (previous == TokenKind.Dot)
			return typePathStartsInContext(index);
		if (previous == TokenKind.LeftParen)
			return startsFunctionTypeAt(index - 1);
		if (previous == TokenKind.Arrow)
			return functionTypeResultAt(index);
		if (previous == TokenKind.Comma)
			return insideTypeArguments(index) || insideFunctionType(index) || precededByEither(TokenKind.Extends, TokenKind.Implements, index);
		return precededBy(TokenKind.Import, index) && followedBy(TokenKind.Semicolon, index);
	}

	/** Whether the parenthesized group at open starts a source function type. */
	function startsFunctionTypeAt(open:Int):Bool {
		if (open < 0 || open >= tokens.length || tokens[open].kind != TokenKind.LeftParen)
			return false;
		var close = matchingRightParen(open);
		return close >= 0 && close + 1 < tokens.length && tokens[close + 1].kind == TokenKind.Arrow
			&& typeContextBeforeFunctionType(open);
	}

	function matchingRightParen(open:Int):Int {
		var depth = 0;
		for (index in open...tokens.length)
			switch tokens[index].kind {
				case LeftParen:
					depth++;
				case RightParen:
					depth--;
					if (depth == 0)
						return index;
				default:
				}
		return -1;
	}

	function typeContextBeforeFunctionType(open:Int):Bool {
		if (open <= 0)
			return false;
		return switch tokens[open - 1].kind {
			case Colon, Less, Comma: true;
			case Arrow: true;
			case Assign: precededBy(TokenKind.Typedef, open);
			case LeftParen: insideFunctionType(open - 1);
			default: false;
		};
	}

	/** Whether an identifier is one of the argument types in a function type. */
	function insideFunctionType(index:Int):Bool {
		if (index <= 0)
			return false;
		for (open in 0...index)
			if (tokens[open].kind == TokenKind.LeftParen && startsFunctionTypeAt(open)) {
				var close = matchingRightParen(open);
				if (close > index)
					return true;
			}
		return false;
	}

	/** Whether an identifier starts the result type after a function-type arrow. */
	function functionTypeResultAt(index:Int):Bool {
		if (index <= 1 || tokens[index - 1].kind != TokenKind.Arrow || tokens[index - 2].kind != TokenKind.RightParen)
			return false;
		var close = index - 2, depth = 0;
		for (open in 0...(close + 1)) {
			var cursor = close - open;
			switch tokens[cursor].kind {
				case RightParen:
					depth++;
				case LeftParen:
					depth--;
					if (depth == 0)
						return startsFunctionTypeAt(cursor);
				default:
			}
		}
		return false;
	}

	function qualifiedTokenName(index:Int):String {
		var start = index;
		while (start >= 2 && tokens[start - 1].kind == TokenKind.Dot && tokens[start - 2].kind == TokenKind.Identifier)
			start -= 2;
		var parts:Array<String> = [];
		for (cursor in start...index + 1)
			if (tokens[cursor].kind == TokenKind.Identifier)
				parts.push(tokens[cursor].text);
		return parts.join(".");
	}

	function typePathStartsInContext(index:Int):Bool {
		var start = index;
		while (start >= 2 && tokens[start - 1].kind == TokenKind.Dot && tokens[start - 2].kind == TokenKind.Identifier)
			start -= 2;
		if (start == 0)
			return false;
		var kind = tokens[start - 1].kind;
		return kind == TokenKind.Colon
			|| kind == TokenKind.Extends
			|| kind == TokenKind.Implements
			|| kind == TokenKind.Less
			|| (kind == TokenKind.Assign && precededBy(TokenKind.Typedef, start))
			|| precededBy(TokenKind.Import, start);
	}

	function insideTypeArguments(index:Int):Bool {
		var depth = 0, cursor = index - 1;
		while (cursor >= 0) {
			switch tokens[cursor].kind {
				case Greater:
					depth++;
				case Less:
					if (depth == 0)
						return true;
					depth--;
				case Semicolon, LeftBrace, RightBrace, Assign:
					return false;
				default:
			}
			cursor--;
		}
		return false;
	}

	function precededBy(kind:TokenKind, index:Int):Bool {
		var cursor = index - 1;
		while (cursor >= 0) {
			var candidate = tokens[cursor].kind;
			if (candidate == kind)
				return true;
			if (candidate == TokenKind.Semicolon || candidate == TokenKind.LeftBrace || candidate == TokenKind.RightBrace)
				return false;
			cursor--;
		}
		return false;
	}

	function precededByEither(left:TokenKind, right:TokenKind, index:Int):Bool
		return precededBy(left, index) || precededBy(right, index);

	function followedBy(kind:TokenKind, index:Int):Bool {
		var cursor = index + 1;
		while (cursor < tokens.length) {
			var candidate = tokens[cursor].kind;
			if (candidate == kind)
				return true;
			if (candidate != TokenKind.Dot && candidate != TokenKind.Identifier)
				return false;
			cursor++;
		}
		return false;
	}

	function bindLocalUse(fn:TypedFunction, identity:String, span:SourceSpan):Void {
		var id = localId(fn, identity),
			token = referenceToken(tokens, span, sourceLocalName(identity));
		if (symbols.exists(id) && token != null)
			bind(id, token.span);
	}

	/**
	 * Recover a lexical local when a typed call was lowered to a qualified
	 * function name. This is needed for tolerant typing paths that preserve the
	 * callable result but lose the original TClosureCall wrapper.
	 */
	function localBindingAt(fn:TypedFunction, name:String, position:Int):Null<SemanticSymbolId> {
		var localName = name,
			separator = name.lastIndexOf(".");
		if (separator >= 0) {
			if (name.substring(0, separator) != module)
				return null;
			localName = name.substring(separator + 1);
		}
		var selected:Null<SemanticCompletionLocal> = null;
		for (local in completionLocals) {
			if (local.name != sourceLocalName(localName)
				|| position < local.declaration.end
				|| position < local.scope.start
				|| position > local.scope.end)
				continue;
			if (selected == null
				|| local.depth > selected.depth
				|| local.depth == selected.depth && local.declaration.start > selected.declaration.start)
				selected = local;
		}
		if (selected == null)
			return null;
		for (symbol in symbols)
			if (StringTools.startsWith(Std.string(symbol.id), module + ":local:" + fn.name + ":")
				&& symbol.name == selected.name
				&& symbol.declaration.file.path == selected.declaration.file.path
				&& symbol.declaration.start == selected.declaration.start
				&& symbol.declaration.end == selected.declaration.end)
				return symbol.id;
		return null;
	}

	function bindNamed(resolve:String->Null<SemanticSymbolId>, name:String, span:SourceSpan):Null<SemanticSymbolId> {
		var sourceNameValue = semanticSourceName(name),
			id = resolve(sourceNameValue),
			token = referenceToken(tokens, span, sourceName(sourceNameValue));
		// Same-module declarations are already present in this index even when
		// workspace resolution is temporarily unavailable while the exact model
		// is being assembled. Keep those references bound locally; do not invent
		// an identity for declarations that are not in the current index.
		if (id == null)
			for (symbol in symbols)
				if (symbol.name == sourceNameValue) {
					id = symbol.id;
					break;
				}
		if (id != null) {
			bind(id, token == null ? span : token.span);
			recordResolvedReference(name, id);
		}
		return id;
	}

	/** Map generated generic ABI calls back to their source declaration. */
	static function semanticSourceName(name:String):String {
		var prefix = "$generic:";
		if (!StringTools.startsWith(name, prefix))
			return name;
		var originStart = prefix.length,
			originEnd = name.indexOf("[", originStart);
		return originEnd < 0 ? name.substr(originStart) : name.substring(originStart, originEnd);
	}

	function bindMember(resolve:String->Null<SemanticSymbolId>, type:CompilerType, name:String, span:SourceSpan):Null<SemanticSymbolId> {
		var owner = switch type {
			case TNullable(element): memberOwner(element);
			default: memberOwner(type);
		};
		return owner == null ? null : bindNamed(resolve, owner + "." + name, span);
	}

	static function memberName(name:String):String {
		var separator = name.lastIndexOf(".");
		return separator < 0 ? name : name.substring(separator + 1);
	}

	function bindEnumCase(resolve:(String, Int) -> Null<SemanticSymbolId>, enumName:Null<String>, index:Int, span:SourceSpan):Void {
		if (enumName == null || index < 0)
			return;
		var id = resolve(enumName, index);
		if (id != null) {
			recordResolvedReference(enumName, id);
			var token = enumReferenceToken(tokens, span, sourceName(Std.string(id)));
			if (token != null)
				bind(id, token.span);
		}
	}

	function recordResolvedReference(target:String, targetId:SemanticSymbolId):Void {
		if (frozen)
			return;
		if (currentCallerName == null)
			return;
		for (edge in resolvedReferences)
			if (edge.owner == currentCallerName && edge.targetId == targetId && edge.kind == currentDependencyKind)
				return;
		resolvedReferences.push({
			owner: currentCallerName,
			target: target,
			targetId: targetId,
			kind: currentDependencyKind
		});
	}

	static function enumReferenceToken(tokens:Array<Token>, expression:SourceSpan, name:String):Null<Token> {
		var token = referenceToken(tokens, expression, name);
		if (token != null)
			return token;
		for (candidate in tokens)
			if (candidate.kind == TokenKind.Identifier
				&& candidate.text == name
				&& candidate.span.start >= expression.end
				&& candidate.span.start <= expression.end + 2)
				return candidate;
		return null;
	}

	static function memberOwner(type:CompilerType):Null<String>
		return switch type {
			case TNullable(element): memberOwner(element);
			case TInstance(_, name, _), TAbstract(name, _, _): name;
			default: null;
		};

	function recoveredTypeSubstitutions(type:CompilerType):Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		switch type {
			case TNullable(element):
				return recoveredTypeSubstitutions(element);
			case TInstance(_, name, arguments):
			var parameters:Null<Array<String>> = null,
				classDecl = declarations.classes.get(name),
				interfaceDecl = declarations.interfaces.get(name),
				abstractDecl = declarations.abstracts.get(name),
				enumDecl = declarations.enums.get(name);
			if (classDecl != null)
				parameters = classDecl.typeParameters;
			else if (interfaceDecl != null)
				parameters = interfaceDecl.typeParameters;
			else if (abstractDecl != null)
				parameters = abstractDecl.typeParameters;
			else if (enumDecl != null)
				parameters = enumDecl.typeParameters;
				if (parameters != null)
					for (index in 0...parameters.length)
						if (index < arguments.length)
							result.set(parameters[index], arguments[index]);
			case TAbstract(name, arguments, _):
				var abstractDecl = declarations.abstracts.get(name);
				if (abstractDecl != null)
					for (index in 0...abstractDecl.typeParameters.length)
						if (index < arguments.length)
							result.set(abstractDecl.typeParameters[index], arguments[index]);
			default:
		}
		return result;
	}

	function localId(fn:TypedFunction, identity:String):SemanticSymbolId
		return new SemanticSymbolId(module, 'local:${fn.name}:$identity');

	static function sourceLocalName(identity:String):String {
		var separator = identity.indexOf(":");
		return StringTools.startsWith(identity, "$l") && separator >= 0 ? identity.substr(separator + 1) : identity;
	}

	static function declarationToken(tokens:Array<Token>, declaration:SourceSpan, name:String):Null<Token> {
		var index = tokenIndexAtOrAfter(tokens, declaration.start);
		while (index < tokens.length) {
			var token = tokens[index++];
			if (token.span.start >= declaration.end)
				break;
			if (token.span.end <= declaration.end && token.kind == TokenKind.Identifier && token.text == name)
				return token;
		}
		return null;
	}

	static function referenceToken(tokens:Array<Token>, expression:SourceSpan, name:String):Null<Token> {
		var index = tokenIndexAtOrAfter(tokens, expression.start);
		while (index < tokens.length) {
			var token = tokens[index++];
			if (token.span.start >= expression.end)
				break;
			if (token.span.end <= expression.end && token.kind == TokenKind.Identifier && token.text == name)
				return token;
		}
		return null;
	}

	/** Find the first token whose source range starts at or after an offset. */
	static function tokenIndexAtOrAfter(tokens:Array<Token>, offset:Int):Int {
		var low = 0, high = tokens.length;
		while (low < high) {
			var middle = low + ((high - low) >> 1);
			if (tokens[middle].span.start < offset)
				low = middle + 1;
			else
				high = middle;
		}
		return low;
	}

	static function sourceName(name:String):String {
		var separator = name.lastIndexOf(".");
		return separator < 0 ? name : name.substr(separator + 1);
	}

	static function displayType(type:CompilerType):String
		return switch type {
			case TInt: "Int";
			case TInt64: "haxe.Int64";
			case TFloat: "Float";
			case TBool: "Bool";
			case TString: "String";
			case TVoid: "Void";
			case TArray(element): 'Array<${displayType(element)}>';
			case TIterator(element): 'Iterator<${displayType(element)}>';
			case TMap(key, value): 'Map<${displayType(key)},${displayType(value)}>';
			case TNullable(element): 'Null<${displayType(element)}>';
			case TTypeParameter(_, name): name;
			case TInstance(_, name, arguments): arguments.length == 0 ? name : name
					+ "<"
					+ [for (argument in arguments) displayType(argument)].join(",") + ">";
			case TFunction(arguments, result): "(" + [for (argument in arguments) displayType(argument)].join(",") + ")->" + displayType(result);
			default: Std.string(type);
		};

	static function displayAstType(type:AstType):String
		return switch type {
			case IntType: "Int";
			case BoolType: "Bool";
			case FloatType: "Float";
			case StringType: "String";
			case VoidType: "Void";
			case InferredType: "_";
			case NamedType(name): name;
			case AppliedType(name, arguments): name + "<" + [for (argument in arguments) displayAstType(argument)].join(",") + ">";
			case ArrayType(element): 'Array<${displayAstType(element)}>';
			case MapType(key, value): 'Map<${displayAstType(key)},${displayAstType(value)}>';
			case NullableType(element): 'Null<${displayAstType(element)}>';
			case FunctionType(arguments, result): "(" + [for (argument in arguments) displayAstType(argument)].join(",") + ")->" + displayAstType(result);
			default: Std.string(type);
		};
}

/**
 * Frozen query facade for one semantic revision. Construction is deliberately
 * unavailable here; callers must obtain a SemanticIndexBuilder and publish it
 * with SemanticIndexBuilder.freeze().
 */
@:allow(compiler.semantic.SemanticIndexBuilder)
class SemanticIndex {
	/** Construction-only access. Null after publication. */
	final construction:Null<SemanticIndexBuilder>;
	final queryState:Null<SemanticIndexQueryState>;

	public var revision(get, never):Int;
	public var symbols(get, never):Map<String, IndexedSemanticSymbol>;
	public var indexingMs(get, never):Float;

	private function new(builder:SemanticIndexBuilder, ?queryState:SemanticIndexQueryState) {
		this.construction = queryState == null ? builder : null;
		this.queryState = queryState;
	}

	function activeConstruction():SemanticIndexBuilder {
		var builder = construction;
		if (builder == null)
			throw "Published semantic index has no construction state";
		return builder;
	}

	function get_revision():Int
		return queryState == null ? activeConstruction().revision : queryState.revision;

	function get_symbols():Map<String, IndexedSemanticSymbol>
		return queryState == null ? activeConstruction().snapshotSymbols() : queryState.snapshotSymbols();

	function get_indexingMs():Float
		return queryState == null ? activeConstruction().indexingMs : queryState.indexingMs;

	public function symbolIdAt(position:Int, ?token:CancellationToken):Null<SemanticSymbolId> {
		if (queryState != null)
			return queryState.symbolIdAt(position, token);
		var builder = activeConstruction();
		var selected:Null<PositionBinding> = null;
		for (binding in builder.bindings) {
			if (token != null)
				token.check();
			if (position < binding.span.start || position > binding.span.end)
				continue;
			var width = binding.span.end - binding.span.start,
				selectedWidth = selected == null ? 0x3fffffff : selected.span.end - selected.span.start;
			if (selected == null || width < selectedWidth
				|| width == selectedWidth && binding.span.start > selected.span.start)
				selected = binding;
		}
		return selected == null ? null : selected.symbol;
	}

	public function symbolAt(position:Int):Null<IndexedSemanticSymbol> {
		if (queryState != null)
			return queryState.symbolAt(position);
		var id = symbolIdAt(position);
		return id == null ? null : activeConstruction().symbols.get(id);
	}

	public function symbol(id:SemanticSymbolId):Null<IndexedSemanticSymbol>
		return queryState == null ? activeConstruction().symbols.get(id) : queryState.symbol(id);

	public function signature(id:SemanticSymbolId):Null<SemanticSignatureInfo>
		return queryState == null ? copySignature(activeConstruction().signatures.get(id)) : queryState.signature(id);

	public function typeParameterId(owner:String, name:String):Null<SemanticSymbolId>
		return queryState == null
			? activeConstruction().typeParameterIds.get(SemanticIndexBuilder.typeParameterKey(owner, name))
			: queryState.typeParameterId(owner, name);

	public function calls():Array<SemanticCallEdge> {
		if (queryState != null)
			return queryState.calls();
		var builder = activeConstruction();
		if (!builder.isFrozen)
			builder.completeCallEdges();
		return [for (edge in builder.callEdges) {caller: edge.caller, callee: edge.callee, span: edge.span}];
	}

	public function resolvedDependencies():Array<ResolvedSemanticReference>
		return queryState == null ? [for (reference in activeConstruction().resolvedReferences) {
			owner: reference.owner,
			target: reference.target,
			targetId: reference.targetId,
			kind: reference.kind
		}] : queryState.resolvedDependencies();

	public function locations(id:SemanticSymbolId):Array<SourceSpan> {
		if (queryState != null)
			return queryState.locations(id);
		var result = activeConstruction().references.get(id);
		return result == null ? [] : result.copy();
	}

	public function completionContext(position:Int, ?qualifier:String, ?token:CancellationToken):SemanticCompletionContext
		return queryState == null
			? activeConstruction().completionContext(position, qualifier, token)
			: queryState.completionContext(position, qualifier, token);

	public function unresolvedSymbols():Array<UnresolvedSymbol>
		return queryState == null ? [for (symbol in activeConstruction().unresolved)
			{name: symbol.name, span: symbol.span, candidates: symbol.candidates.copy()}] : queryState.unresolvedSymbols();

	public function unresolvedAt(position:Int):Null<UnresolvedSymbol> {
		if (queryState != null)
			return queryState.unresolvedAt(position);
		for (symbol in activeConstruction().unresolved)
			if (position >= symbol.span.start && position <= symbol.span.end)
				return {name: symbol.name, span: symbol.span, candidates: symbol.candidates.copy()};
		return null;
	}

	public function typeAt(position:Int, ?token:CancellationToken):Null<CompilerType> {
		if (queryState != null)
			return queryState.typeAt(position, token);
		var builder = activeConstruction();
		var symbol = symbolIdAt(position, token);
		if (symbol != null && builder.declarationTypes.exists(symbol))
			return builder.declarationTypes.get(symbol);
		var result:Null<CompilerType> = null, width = 0x3fffffff;
		for (candidate in builder.completionTypes) {
			if (token != null)
				token.check();
			if (position >= candidate.span.start && position <= candidate.span.end && candidate.span.end - candidate.span.start < width) {
				result = candidate.type;
				width = candidate.span.end - candidate.span.start;
			}
		}
		for (local in builder.completionLocals) {
			if (token != null)
				token.check();
			if (position >= local.declaration.start && position <= local.declaration.end)
				return local.type;
		}
		if (result != null)
			return result;
		return symbol == null ? null : builder.declarationTypes.get(symbol);
	}

	public function recoveredSignature(name:String, ?receiverType:CompilerType):Null<SemanticSignatureInfo>
		return queryState == null
			? copySignature(activeConstruction().recoveredSignature(name, receiverType))
			: queryState.recoveredSignature(name, receiverType);

	public function callableSignature(type:Null<CompilerType>, name:String):Null<SemanticSignatureInfo>
		return queryState == null
			? copySignature(activeConstruction().callableSignature(type, name))
			: queryState.callableSignature(type, name);

	static function copySignature(signature:Null<SemanticSignatureInfo>):Null<SemanticSignatureInfo>
		return signature == null ? null : {
			label: signature.label,
			parameters: signature.parameters.copy(),
			result: signature.result
		};
}
