package compiler.semantic;

import compiler.Source.SourceSpan;
import compiler.modules.ModulePath;
import compiler.syntax.Token;
import compiler.syntax.Token.TokenKind;
import compiler.types.DeclarationIndex;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.Type.CompilerType;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstExpression;
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

/** Revision-local declaration and resolved-local facts emitted by the compiler. */
class SemanticIndex {
	public final revision:Int;
	public final symbols:Map<String, IndexedSemanticSymbol> = [];
	public var indexingMs(default, null):Float = 0.0;

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
	final declarations:DeclarationIndex;
	final tokens:Array<Token>;
	final module:String;
	var cancellation:Null<CancellationToken>;
	var recoveryResolve:Null<String->Null<SemanticSymbolId>>;
	var recoveryResolveEnumCase:Null<(String, Int) -> Null<SemanticSymbolId>>;
	var recoveryResolveType:Null<(String, Array<CompilerType>) -> Null<CompilerType>>;
	var currentCaller:Null<SemanticSymbolId>;
	var currentCallerName:Null<String>;
	var currentDependencyKind:SemanticDependencyKind = SemanticDependencyKind.Body;
	var checkpointCount:Int = 0;

	public function new(path:String, revision:Int, declarations:DeclarationIndex, tokens:Array<Token>) {
		module = ModulePath.fromFile(path);
		this.revision = revision;
		this.declarations = declarations;
		this.tokens = tokens;
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

	function indexDeclarationTypes(owner:String, fields:Array<compiler.syntax.Ast.AstField>, methods:Array<compiler.syntax.Ast.AstFunction>,
			declarations:DeclarationIndex):Void {
		for (field in fields)
			if (field.type != null)
				try
					setDeclarationType(owner + "." + field.name, field.span, declarations.resolve(field.type, field.span))
				catch (_:Dynamic) {}
		for (method in methods)
			try
				setDeclarationType(owner + "." + method.name, method.span, declarations.resolve(method.result, method.span))
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

	public function indexTypedFunction(fn:TypedFunction, resolve:String->Null<SemanticSymbolId>, resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>,
			?token:CancellationToken, ?deferBindingSort = false):Void {
		var started = Sys.time();
		if (token != null)
			token.check();
		cancellation = token;
		checkpoint();
		for (argument in fn.arguments) {
			declareLocal(fn, argument.name, fn.span);
			addCompletionLocal(argument.name, argument.type, fn.span, fn.span, 0);
		}
		if (fn.owner != null)
			functionReceivers.push({span: fn.span, type: TInstance(compiler.types.Type.NominalKind.Class, fn.owner, [])});
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

	/** Index usable local facts from a recovered syntax tree without requiring successful typing. */
	public function indexRecoveredSyntax(program:AstProgram, ?token:CancellationToken, ?typedProgram:TypedProgram, ?resolve:String->Null<SemanticSymbolId>,
			?resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>, ?resolveType:(String, Array<CompilerType>) -> Null<CompilerType>):Void {
		cancellation = token;
		recoveryResolve = resolve;
		recoveryResolveEnumCase = resolveEnumCase;
		recoveryResolveType = resolveType;
		if (token != null)
			token.check();
		for (fn in program.functions) {
			checkpoint();
			recoveredFunctions.set(fn.name, fn);
		}
		for (owner in program.classes) {
			checkpoint();
			if (owner.base != null)
				recoveredClassBases.set(owner.name, recoveredType(owner.base));
			for (fn in owner.methods)
				recoveredFunctions.set(owner.name + "." + fn.name, fn);
		}
		for (owner in program.interfaces) {
			checkpoint();
			for (fn in owner.methods)
				recoveredFunctions.set(owner.name + "." + fn.name, fn);
		}
		for (owner in program.abstracts) {
			checkpoint();
			for (fn in owner.methods)
				recoveredFunctions.set(owner.name + "." + fn.name, fn);
		}
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
				indexRecoveredFunction(fn, owner.name);
		}
		for (owner in program.interfaces) {
			checkpoint();
			for (fn in owner.methods)
				indexRecoveredFunction(fn, owner.name);
		}
		for (owner in program.abstracts) {
			checkpoint();
			for (fn in owner.methods)
				indexRecoveredFunction(fn, owner.name);
		}
		if (typedProgram != null)
			for (fn in typedProgram.functions) {
				checkpoint();
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
		recoveryResolveEnumCase = null;
		recoveryResolveType = null;
	}

	/** Index signatures from a visible module for editor-only recovery queries. */
	public function indexRecoveredModule(program:AstProgram, external:DeclarationIndex, qualifiers:Array<String>, ?token:CancellationToken):Void {
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
	public function recoveredSignature(name:String):Null<SemanticSignatureInfo> {
		var fn = recoveredFunction(name);
		if (fn == null)
			fn = recoveredFunction(name + ".new");
		if (fn == null)
			return null;
		var parameters = [
			for (argument in fn.arguments)
				argument.name + ":" + displayAstType(argument.type)
		];
		return {
			label: sourceName(name) + "(" + parameters.join(",") + "):" + displayAstType(fn.result),
			parameters: parameters,
			result: displayAstType(fn.result)
		};
	}

	function rememberRecoveredMember(owner:String, name:String, span:SourceSpan):Void
		for (symbol in symbols)
			if (sourceName(symbol.name) == name && symbol.declaration.start >= span.start && symbol.declaration.end <= span.end) {
				recoveredMembers.set(owner + "." + name, symbol.id);
				return;
			}

	function indexRecoveredFunction(fn:AstFunction, owner:Null<String>):Void {
		var functionKey = (owner == null ? "" : owner + ".") + fn.name;
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
		if (owner != null)
			functionReceivers.push({span: fn.span, type: TInstance(compiler.types.Type.NominalKind.Class, owner, [])});
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
	}

	function recoveredDeclaredSymbol(name:String):Null<SemanticSymbolId> {
		var ids = symbolIdsByName.get(name);
		if (ids != null)
			for (id in ids)
				if (Std.string(id).indexOf(":local:") < 0)
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
			if (declaration.name == name && index >= 0 && index < declaration.cases.length)
				return recoveredDeclaredSymbol(name + "." + declaration.cases[index].name);
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
					addRecoveredLocal(functionKey, name, recoveredType(type), span, scope, depth);
				case VarDeclaration(name, type, initializer, span):
					var localType = type == null ? recoveredExpressionType(initializer) : recoveredType(type);
					addRecoveredLocal(functionKey, name, localType, span, scope, depth);
					if (type != null)
						completionTypes.push({span: span, type: localType});
				case If(_, yes, no, span):
					indexRecoveredStatements(functionKey, yes, span, depth + 1);
					indexRecoveredStatements(functionKey, no, span, depth + 1);
				case While(_, body, span), DoWhile(body, _, span), ForIn(_, _, _, body, span):
					indexRecoveredStatements(functionKey, body, span, depth + 1);
				case Try(body, catches, span):
					indexRecoveredStatements(functionKey, body, span, depth + 1);
					for (caught in catches) {
						addRecoveredLocal(functionKey, caught.name, recoveredType(caught.type), caught.span, caught.span, depth + 1);
						indexRecoveredStatements(functionKey, caught.statements, caught.span, depth + 1);
					}
				case Switch(_, cases, fallback, _, span):
					for (item in cases)
						indexRecoveredStatements(functionKey, item.statements, item.span, depth + 1);
					indexRecoveredStatements(functionKey, fallback, span, depth + 1);
				default:
			}
		}
	}

	function addRecoveredLocal(functionKey:String, name:String, type:CompilerType, declaration:SourceSpan, scope:SourceSpan, depth:Int):Void {
		var token = declarationToken(tokens, declaration, name);
		if (token == null)
			return;
		var next = recoveredLocalNext.exists(functionKey) ? recoveredLocalNext.get(functionKey) : 0;
		recoveredLocalNext.set(functionKey, next + 1);
		var id = new SemanticSymbolId(module, 'local:' + functionKey + ':' + '$' + 'l' + next + ':' + name);
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

	function indexRecoveredStatementUses(statements:Array<AstStatement>, ?expectedReturn:CompilerType):Void {
		for (statement in statements) {
			checkpoint();
			switch statement {
				case VarDeclaration(_, type, value, span):
					if (type != null)
						completionTypes.push({span: span, type: recoveredType(type)});
					indexRecoveredExpression(value, type == null ? null : recoveredType(type));
				case Return(value, span):
					indexRecoveredExpression(value, expectedReturn);
				case Throw(value, _), Expression(value, _):
					indexRecoveredExpression(value);
				case Assignment(name, value, span):
					bindRecoveredLocal(name, span);
					indexRecoveredExpression(value, recoveredLocalType(name, span));
				case Increment(name, _, span):
					bindRecoveredLocal(name, span);
				case IndexAssignment(array, offset, value, _):
					indexRecoveredExpression(array);
					indexRecoveredExpression(offset, TInt);
					indexRecoveredExpression(value, indexedValueType(recoveredExpressionType(array)));
				case FieldAssignment(object, field, value, span):
					bindRecoveredMember(object, field, span);
					indexRecoveredExpression(object);
					indexRecoveredExpression(value, recoveredMemberType(object, field));
				case If(predicate, yes, no, _):
					indexRecoveredExpression(predicate);
					indexRecoveredStatementUses(yes, expectedReturn);
					indexRecoveredStatementUses(no, expectedReturn);
				case While(predicate, body, _):
					indexRecoveredExpression(predicate);
					indexRecoveredStatementUses(body, expectedReturn);
				case DoWhile(body, predicate, _):
					indexRecoveredStatementUses(body, expectedReturn);
					indexRecoveredExpression(predicate);
				case ForIn(_, _, iterable, body, _):
					indexRecoveredExpression(iterable);
					indexRecoveredStatementUses(body, expectedReturn);
				case Try(body, catches, _):
					indexRecoveredStatementUses(body, expectedReturn);
					for (caught in catches)
						indexRecoveredStatementUses(caught.statements, expectedReturn);
				case Switch(value, cases, fallback, _, _):
					var expectedPattern = recoveredExpressionType(value);
					indexRecoveredExpression(value);
					for (item in cases) {
						indexRecoveredExpression(item.value, expectedPattern);
						if (item.guard != null)
							indexRecoveredExpression(item.guard);
						indexRecoveredStatementUses(item.statements, expectedReturn);
					}
					indexRecoveredStatementUses(fallback, expectedReturn);
				default:
			}
		}
	}

	function indexRecoveredExpression(expression:AstExpression, ?expected:CompilerType):Void {
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
					bindRecoveredLocal(receiver, span);
					if (bindRecoveredMember(Variable(receiver, span), member, span) == null)
						bindNamed(resolveRecoveredSymbol, name, span);
				}
			case Member(object, name, span):
				indexRecoveredExpression(object);
				if (bindRecoveredMember(object, name, span) == null && name.length > 0 && !isKnownRecoveredMember(object, name))
					recordUnresolved(name, span);
			case Call(name, arguments, span):
				var separator = name.lastIndexOf(".");
				if (separator > 0) {
					var receiverName = name.substring(0, separator),
						memberName = name.substring(separator + 1),
						receiver = Variable(receiverName, span),
						callee = bindRecoveredMember(receiver, memberName, span);
					if (callee == null)
						callee = bindNamed(resolveRecoveredSymbol, name, span);
					var owner = memberOwner(recoveredExpressionBindingType(receiver));
					if (callee == null && !isKnownRecoveredMember(receiver, memberName))
						recordUnresolved(memberName, span);
					addCall(callee, span, memberName);
					indexRecoveredCallArguments(arguments, owner == null ? null : recoveredMethod(owner, memberName, []));
				} else {
					var local = bindRecoveredLocal(name, span);
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
					indexRecoveredCallArguments(arguments, recoveredFunctionForCall(name));
				}
			case ClosureCall(callee, arguments, _):
				indexRecoveredExpression(callee);
				for (index in 0...arguments.length)
					indexRecoveredExpression(arguments[index], expectedFunctionArgument(recoveredExpressionType(callee), index));
			case MethodCall(object, name, arguments, span):
				indexRecoveredExpression(object);
				var callee = bindRecoveredMember(object, name, span);
				addCall(callee, span, name);
				if (callee == null && !isKnownRecoveredMember(object, name))
					recordUnresolved(name, span);
				var owner = memberOwner(recoveredExpressionBindingType(object));
				indexRecoveredCallArguments(arguments, owner == null ? null : recoveredMethod(owner, name, []));
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), BitAnd(left, right, _),
				BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _), UnsignedShiftRight(left, right, _),
				Less(left, right, _), LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _),
				NotEqual(left, right, _), And(left, right, _), Or(left, right, _):
				indexRecoveredExpression(left);
				indexRecoveredExpression(right);
			case Index(array, offset, _):
				indexRecoveredExpression(array);
				indexRecoveredExpression(offset, TInt);
			case Range(start, finish, _):
				indexRecoveredExpression(start);
				indexRecoveredExpression(finish);
			case Negate(value, _), Not(value, _), ThrowExpression(value, _), PostfixIncrement(value, _, _):
				indexRecoveredExpression(value);
			case Cast(value, target, _):
				indexRecoveredExpression(value, target == null ? expected : recoveredType(target));
			case Conditional(predicate, yes, no, _):
				indexRecoveredExpression(predicate);
				indexRecoveredExpression(yes, expected);
				indexRecoveredExpression(no, expected);
			case BlockExpression(statements, result, _):
				indexRecoveredStatementUses(statements, expected);
				indexRecoveredExpression(result, expected);
			case ArrayLiteral(values, _):
				for (value in values)
					indexRecoveredExpression(value, indexedValueType(expected));
			case ObjectLiteral(fields, _):
				for (field in fields)
					indexRecoveredExpression(field.value, expectedFieldType(expected, field.name));
			case MapLiteral(entries, _):
				for (entry in entries) {
					indexRecoveredExpression(entry.key, mapKeyType(expected));
					indexRecoveredExpression(entry.value, mapValueType(expected));
				}
			case New(name, arguments, _), NewGeneric(name, _, arguments, _):
				indexRecoveredCallArguments(arguments, recoveredFunctionForCall(name));
			case NewArray(_, length, _):
				indexRecoveredExpression(length, TInt);
			case Lambda(_, body, _):
				indexRecoveredStatementUses(body, functionResultType(expected));
			case SwitchExpression(value, cases, fallback, _):
				var expectedPattern = recoveredExpressionType(value);
				indexRecoveredExpression(value);
				for (item in cases) {
					indexRecoveredExpression(item.value, expectedPattern);
					if (item.guard != null)
						indexRecoveredExpression(item.guard);
					indexRecoveredExpression(item.result, expected);
				}
				if (fallback != null)
					indexRecoveredExpression(fallback, expected);
			default:
		}
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

	function bindRecoveredMember(object:AstExpression, name:String, span:SourceSpan):Null<SemanticSymbolId> {
		var owner = switch recoveredExpressionBindingType(object) {
			case TNullable(element): memberOwner(element);
			case type: memberOwner(type);
		};
		if (owner == null)
			return null;
		var id = recoveredMembers.get(owner + "." + name);
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
		var owner = switch recoveredExpressionBindingType(object) {
			case TNullable(element): memberOwner(element);
			case type: memberOwner(type);
		};
		return owner != null
			&& (knownRecoveredMembers.exists(owner + "." + name)
				|| recoveredFieldType(owner, name, []) != null
				|| recoveredMethod(owner, name, []) != null);
	}

	function recoveredExpressionBindingType(expression:AstExpression):CompilerType
		return switch expression {
			case Variable(name, span):
				var id = bindRecoveredLocal(name, span);
				if (id != null && declarationTypes.exists(id)) declarationTypes.get(id); else if (declarations.classes.exists(name))
					TInstance(compiler.types.Type.NominalKind.Class, name,
					[]); else if (declarations.interfaces.exists(name)) TInstance(compiler.types.Type.NominalKind.Interface, name, []); else TUnknown;
			case New(name, _, _), NewGeneric(name, _, _, _): TInstance(compiler.types.Type.NominalKind.Class, name, []);
			default: recoveredExpressionType(expression);
		};

	function recoveredExpressionType(expression:AstExpression):CompilerType
		return switch expression {
			case ErrorExpression(_): TError;
			case IntegerLiteral(_, _): TInt;
			case FloatLiteral(_, _): TFloat;
			case StringLiteral(_, _): TString;
			case BoolLiteral(_, _): TBool;
			case Variable(name, span): recoveredExpressionBindingType(Variable(name, span));
			case Member(object, name, _): recoveredMemberType(object, name);
			case MethodCall(object, name, _, _):
				var owner = memberOwner(recoveredExpressionBindingType(object));
				owner == null ? TUnknown : recoveredFunctionResult(owner + "." + name);
			case Call(name, _, span):
				var separator = name.lastIndexOf(".");
				if (separator > 0) {
					var receiverName = name.substring(0, separator),
						memberName = name.substring(separator + 1),
						owner = memberOwner(recoveredExpressionBindingType(Variable(receiverName, span)));
					owner == null ? TUnknown : recoveredFunctionResult(owner + "." + memberName);
				} else recoveredFunctionResult(name);
			case ArrayLiteral(values, _): TArray(recoveredArrayElementType(values));
			case MapLiteral(_, _): TMap(TUnknown, TUnknown);
			case New(name, _, _), NewGeneric(name, _, _, _): TInstance(compiler.types.Type.NominalKind.Class, name, []);
			default: TUnknown;
		};

	function recordUnresolved(name:String, span:SourceSpan):Void {
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
		unresolved.push({name: name, span: span, candidates: candidates});
	}

	function recoveredType(type:AstType):CompilerType {
		return switch type {
			case ErrorType(_): TUnknown;
			case IntType: TInt;
			case BoolType: TBool;
			case FloatType: TFloat;
			case StringType: TString;
			case VoidType: TVoid;
			case ArrayType(element): TArray(recoveredType(element));
			case MapType(key, value): TMap(recoveredType(key), recoveredType(value));
			case NullableType(element): TNullable(recoveredType(element));
			case NamedType(name):
				try {
					declarations.resolve(type);
				} catch (_:Dynamic) {
					recoveredExternalType(name, []);
				}
			case AppliedType(name, arguments):
				try {
					declarations.resolve(type);
				} catch (_:Dynamic) {
					recoveredExternalType(name, [for (argument in arguments) recoveredType(argument)]);
				}
			default: TUnknown;
		};
	}

	function recoveredExternalType(name:String, arguments:Array<CompilerType>):CompilerType {
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
		if (recoveryResolveType != null) {
			var recovered = recoveryResolveType(name, arguments);
			if (recovered != null)
				return recovered;
		}
		return TUnknown;
	}

	function recoveredFunctionResult(name:String):CompilerType {
		var fn = recoveredFunction(name);
		return fn == null ? TUnknown : recoveredType(fn.result);
	}

	function recoveredFunctionType(name:String):Null<CompilerType> {
		var fn = recoveredFunction(name);
		return fn == null ? null : TFunction([for (argument in fn.arguments) recoveredType(argument.type)], recoveredType(fn.result));
	}

	function recoveredMemberType(object:AstExpression, name:String):CompilerType {
		checkpoint();
		var owner = memberOwner(recoveredExpressionBindingType(object));
		if (owner == null)
			return TUnknown;
		var fieldType = recoveredFieldType(owner, name, []);
		if (fieldType != null)
			return fieldType;
		var functionType = recoveredFunctionType(owner + "." + name);
		if (functionType != null)
			return functionType;
		return recoveredFunctionResult(owner + "." + name);
	}

	function recoveredFieldType(owner:String, name:String, visiting:Array<String>):Null<CompilerType> {
		if (visiting.indexOf(owner) >= 0)
			return null;
		var nextVisiting = visiting.copy();
		nextVisiting.push(owner);
		var classDecl = declarations.classes.get(owner);
		if (classDecl != null) {
			for (field in classDecl.fields) {
				checkpoint();
				if (field.name == name && !field.isStatic)
					return field.type == null ? (field.initializer == null ? TUnknown : recoveredExpressionType(field.initializer)) : recoveredType(field.type);
			}
			if (classDecl.base != null) {
				var base = memberOwner(recoveredType(classDecl.base));
				if (base != null) {
					var inherited = recoveredFieldType(base, name, nextVisiting);
					if (inherited != null)
						return inherited;
				}
			}
		}
		return null;
	}

	function recoveredMethod(owner:String, name:String, visiting:Array<String>):Null<AstFunction> {
		if (visiting.indexOf(owner) >= 0)
			return null;
		var direct = recoveredFunctions.get(owner + "." + name);
		if (direct != null)
			return direct;
		var nextVisiting = visiting.copy();
		nextVisiting.push(owner);
		var classDecl = declarations.classes.get(owner);
		if (classDecl != null && classDecl.base != null) {
			var base = memberOwner(recoveredType(classDecl.base));
			if (base != null) {
				var inherited = recoveredMethod(base, name, nextVisiting);
				if (inherited != null)
					return inherited;
			}
		}
		var interfaceDecl = declarations.interfaces.get(owner);
		if (interfaceDecl != null)
			for (baseType in interfaceDecl.bases) {
				var base = memberOwner(recoveredType(baseType));
				if (base != null) {
					var inherited = recoveredMethod(base, name, nextVisiting);
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

	function recoveredArrayElementType(values:Array<AstExpression>):CompilerType {
		for (value in values) {
			var type = recoveredExpressionType(value);
			if (type != TUnknown && type != TError)
				return type;
		}
		return TUnknown;
	}

	function indexRecoveredCallArguments(arguments:Array<AstExpression>, fn:Null<AstFunction>):Void {
		for (index in 0...arguments.length) {
			checkpoint();
			var argument = arguments[index];
			var expected = fn == null || index >= fn.arguments.length ? null : recoveredType(fn.arguments[index].type);
			indexRecoveredExpression(argument, expected);
		}
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

	public function symbolIdAt(position:Int, ?token:CancellationToken):Null<SemanticSymbolId> {
		for (binding in bindings) {
			if (token != null)
				token.check();
			if (position >= binding.span.start && position <= binding.span.end)
				return binding.symbol;
		}
		return null;
	}

	public function symbolAt(position:Int):Null<IndexedSemanticSymbol> {
		var id = symbolIdAt(position);
		return id == null ? null : symbols.get(id);
	}

	public function symbol(id:SemanticSymbolId):Null<IndexedSemanticSymbol>
		return symbols.get(id);

	public function signature(id:SemanticSymbolId):Null<SemanticSignatureInfo>
		return signatures.get(id);

	public function calls():Array<SemanticCallEdge> {
		var result = callEdges.copy();
		for (caller in symbols) {
			if (caller.kind != DeclarationKind.Function && caller.kind != DeclarationKind.Member)
				continue;
			var declarationBinding = locations(caller.id);
			for (index in 0...tokens.length) {
				var token = tokens[index];
				if (token.span.start < caller.declaration.start
					|| token.span.end > caller.declaration.end
					|| token.kind != TokenKind.Identifier
					|| index + 1 >= tokens.length
					|| tokens[index + 1].kind != TokenKind.LeftParen
					|| declarationBinding.length > 0
					&& token.span.start == declarationBinding[0].start)
					continue;
				var callee = symbolIdAt(token.span.start);
				if (callee == null)
					continue;
				var duplicate = false;
				for (edge in result)
					if (edge.caller == caller.id && edge.callee == callee && edge.span.start == token.span.start) {
						duplicate = true;
						break;
					}
				if (!duplicate)
					result.push({caller: caller.id, callee: callee, span: token.span});
			}
		}
		return result;
	}

	public function resolvedDependencies():Array<ResolvedSemanticReference>
		return resolvedReferences.copy();

	/** Index a typed field initializer under its field declaration identity. */
	public function indexTypedInitializer(owner:String, expression:TypedExpression, resolve:String->Null<SemanticSymbolId>,
			resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>):Void {
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
		var started = Sys.time();
		if (token != null)
			token.check();
		cancellation = token;
		for (index in 0...tokens.length) {
			checkpoint();
			var token = tokens[index];
			if (token.kind != TokenKind.Identifier || !isTypeReferenceToken(index))
				continue;
			var name = qualifiedTokenName(index), id = resolve(name);
			if (id == null)
				id = resolve(token.text);
			if (id != null)
				bind(id, token.span);
		}
		bindings.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
		checkpoint();
		cancellation = null;
		indexingMs += (Sys.time() - started) * 1000.0;
	}

	public function locations(id:SemanticSymbolId):Array<SourceSpan> {
		var result = references.get(id);
		return result == null ? [] : result.copy();
	}

	public function completionContext(position:Int, ?qualifier:String, ?token:CancellationToken):SemanticCompletionContext {
		var visible:Map<String, SemanticCompletionLocal> = [];
		for (local in completionLocals) {
			if (token != null)
				token.check();
			if (position >= local.declaration.start && position <= local.scope.end) {
				var existing = visible.get(local.name);
				if (existing == null
					|| local.depth > existing.depth
					|| (local.depth == existing.depth && local.declaration.start > existing.declaration.start))
					visible.set(local.name, local);
			}
		}
		var locals = [for (local in visible) local];
		locals.sort(function(left, right) return Reflect.compare(left.name, right.name));
		var overrideContext = isOverrideContext(position, token),
			receiver:Null<CompilerType> = null;
		if (qualifier != null) {
			if (qualifier == "this")
				for (candidate in functionReceivers) {
					if (token != null)
						token.check();
					if (position >= candidate.span.start && position <= candidate.span.end)
						receiver = candidate.type;
				}
			if (receiver == null)
				for (local in locals) {
					if (token != null)
						token.check();
					if (local.name == qualifier)
						receiver = local.type;
				}
		}
		if (receiver == null && overrideContext)
			for (owner in declarations.classes)
				if (position >= owner.span.start && position <= owner.span.end && recoveredClassBases.exists(owner.name)) {
					receiver = recoveredClassBases.get(owner.name);
					break;
				}
		var expected:Null<CompilerType> = null, expectedWidth = 0x3fffffff;
		for (candidate in completionTypes) {
			if (token != null)
				token.check();
			if (position >= candidate.span.start && position <= candidate.span.end) {
				var width = candidate.span.end - candidate.span.start;
				if (width < expectedWidth) {
					expected = candidate.type;
					expectedWidth = width;
				}
			}
		}
		var kind = isImportContext(position, token) ? SemanticCompletionContextKind.Import : qualifier != null ? SemanticCompletionContextKind.Member : overrideContext
			? SemanticCompletionContextKind.Override : expected != null
			&& isObjectFieldContext(position,
				token) ? SemanticCompletionContextKind.ObjectField : isTypeContext(position,
				token) ? SemanticCompletionContextKind.Type : expected != null
			&& isPatternContext(position,
				token) ? SemanticCompletionContextKind.Pattern : expected != null ? SemanticCompletionContextKind.Argument : SemanticCompletionContextKind.Expression;
		return {
			locals: locals,
			receiver: receiver,
			expected: expected,
			kind: kind
		};
	}

	function isTypeContext(position:Int, ?token:CancellationToken):Bool {
		var previous:Null<Token> = null, previousIndex = -1;
		for (lexical in tokens) {
			if (token != null)
				token.check();
			if (lexical.kind == TokenKind.Eof)
				break;
			if (lexical.span.end > position)
				break;
			previous = lexical;
			previousIndex++;
		}
		if (previous == null)
			return false;
		return switch previous.kind {
			case TokenKind.Colon: isTypeColon(previousIndex, token);
			case TokenKind.Extends, TokenKind.Implements, TokenKind.New: true;
			case TokenKind.Identifier, TokenKind.Comma: isTypeNameContext(previousIndex, token);
			case TokenKind.Less: isGenericTypeContext(previousIndex, token);
			default: false;
		};
	}

	function isTypeColon(index:Int, ?token:CancellationToken):Bool {
		var cursor = index - 1;
		while (cursor >= 0) {
			if (token != null)
				token.check();
			switch tokens[cursor].kind {
				case TokenKind.Function, TokenKind.Var, TokenKind.For, TokenKind.Catch:
					return true;
				case TokenKind.Question, TokenKind.Case, TokenKind.Semicolon, TokenKind.LeftBrace, TokenKind.RightBrace, TokenKind.Assign,
					TokenKind.Return, TokenKind.Arrow:
					return false;
				default:
			}
			cursor--;
		}
		return false;
	}

	function isTypeNameContext(index:Int, ?token:CancellationToken):Bool {
		var cursor = index - 1;
		while (cursor >= 0) {
			if (token != null)
				token.check();
			switch tokens[cursor].kind {
				case TokenKind.Colon:
					return isTypeColon(cursor, token);
				case TokenKind.Extends, TokenKind.Implements, TokenKind.New:
					return true;
				case TokenKind.Semicolon, TokenKind.LeftBrace, TokenKind.RightBrace, TokenKind.Assign, TokenKind.Return:
					return false;
				default:
			}
			cursor--;
		}
		return false;
	}

	function isGenericTypeContext(index:Int, ?token:CancellationToken):Bool {
		var cursor = index, depth = 0;
		while (cursor >= 0) {
			if (token != null)
				token.check();
			switch tokens[cursor].kind {
				case TokenKind.Greater:
					depth++;
				case TokenKind.Less:
					if (depth == 0)
						return isTypeNameContext(cursor, token);
					depth--;
				case TokenKind.Semicolon, TokenKind.LeftBrace, TokenKind.RightBrace, TokenKind.Assign, TokenKind.Return:
					return false;
				default:
			}
			cursor--;
		}
		return false;
	}

	function isImportContext(position:Int, ?cancellation:CancellationToken):Bool {
		var previous:Null<Token> = null, previousIndex = -1;
		for (index in 0...tokens.length) {
			if (cancellation != null)
				cancellation.check();
			if (tokens[index].kind == TokenKind.Eof || tokens[index].span.end > position)
				break;
			previous = tokens[index];
			previousIndex = index;
		}
		if (previous == null)
			return false;
		if (previous.kind == TokenKind.Import)
			return true;
		if (previous.kind != TokenKind.Identifier && previous.kind != TokenKind.Dot)
			return false;
		var index = previousIndex - 1;
		while (index >= 0) {
			if (cancellation != null)
				cancellation.check();
			var kind = tokens[index].kind;
			if (kind == TokenKind.Import)
				return true;
			if (kind == TokenKind.Semicolon || kind == TokenKind.LeftBrace || kind == TokenKind.RightBrace)
				return false;
			index--;
		}
		return false;
	}

	function isObjectFieldContext(position:Int, ?cancellation:CancellationToken):Bool {
		var previous:Null<Token> = null;
		for (token in tokens) {
			if (cancellation != null)
				cancellation.check();
			if (token.kind == TokenKind.Eof || token.span.end > position)
				break;
			previous = token;
		}
		if (previous == null || previous.kind != TokenKind.Colon)
			return false;
		var depth = 0;
		var index = tokens.length - 1;
		while (index >= 0) {
			if (cancellation != null)
				cancellation.check();
			var token = tokens[index];
			if (token.span.start >= position) {
				index--;
				continue;
			}
			switch token.kind {
				case TokenKind.RightBrace:
					depth++;
				case TokenKind.LeftBrace:
					if (depth == 0)
						return true;
					depth--;
				default:
			}
			index--;
		}
		return false;
	}

	function isPatternContext(position:Int, ?cancellation:CancellationToken):Bool {
		var index = lastTokenBefore(position);
		while (index >= 0) {
			if (cancellation != null)
				cancellation.check();
			var kind = tokens[index].kind;
			if (kind == TokenKind.Case)
				return true;
			if (kind == TokenKind.Colon || kind == TokenKind.Semicolon || kind == TokenKind.LeftBrace || kind == TokenKind.RightBrace)
				return false;
			index--;
		}
		return false;
	}

	function isOverrideContext(position:Int, ?cancellation:CancellationToken):Bool {
		var index = lastTokenBefore(position);
		if (cancellation != null)
			cancellation.check();
		return index >= 0 && tokens[index].kind == TokenKind.Identifier && tokens[index].text == "override";
	}

	function lastTokenBefore(position:Int):Int {
		var result = -1;
		for (index in 0...tokens.length) {
			if (tokens[index].kind == TokenKind.Eof || tokens[index].span.end > position)
				break;
			result = index;
		}
		return result;
	}

	public function unresolvedSymbols():Array<UnresolvedSymbol>
		return unresolved.copy();

	public function unresolvedAt(position:Int):Null<UnresolvedSymbol> {
		for (symbol in unresolved)
			if (position >= symbol.span.start && position <= symbol.span.end)
				return symbol;
		return null;
	}

	public function typeAt(position:Int, ?token:CancellationToken):Null<CompilerType> {
		var result:Null<CompilerType> = null, width = 0x3fffffff;
		for (candidate in completionTypes) {
			if (token != null)
				token.check();
			if (position >= candidate.span.start && position <= candidate.span.end && candidate.span.end - candidate.span.start < width) {
				result = candidate.type;
				width = candidate.span.end - candidate.span.start;
			}
		}
		for (local in completionLocals) {
			if (token != null)
				token.check();
			if (position >= local.declaration.start && position <= local.declaration.end)
				return local.type;
		}
		if (result != null)
			return result;
		var symbol = symbolIdAt(position, token);
		return symbol == null ? null : declarationTypes.get(symbol);
	}

	function addCompletionLocal(identity:String, type:CompilerType, declaration:SourceSpan, scope:SourceSpan, depth:Int):Void {
		var token = declarationToken(tokens, declaration, sourceLocalName(identity));
		if (token != null)
			completionLocals.push({
				name: sourceLocalName(identity),
				type: type,
				declaration: token.span,
				scope: scope,
				depth: depth
			});
	}

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
					var keyType = switch iterable.type {
						case TArray(element), TMap(element, _): element;
						default: TDynamic;
					};
					addCompletionLocal(name, keyType, span, span, depth + 1);
					if (valueName != null) {
						var valueType = switch iterable.type {
							case TMap(_, value): value;
							default: TDynamic;
						};
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
		for (statement in statements)
			switch statement {
				case TDeclare(name, _, span), TVar(name, _, span):
					declareLocal(fn, name, span);
				case TIf(_, yes, no, _):
					declareLocals(fn, yes);
					declareLocals(fn, no);
				case TWhile(_, body, _), TDoWhile(body, _, _), TForIn(_, _, _, body, _):
					declareLocals(fn, body);
				case TTry(body, catches, _):
					declareLocals(fn, body);
					for (caught in catches)
						declareLocals(fn, caught.statements);
				case TSwitch(_, cases, fallback, _, _):
					for (item in cases)
						declareLocals(fn, item.statements);
					declareLocals(fn, fallback);
				default:
			}
	}

	function declareLocal(fn:TypedFunction, identity:String, within:SourceSpan):Void {
		if (identity == "this")
			return;
		var id = localId(fn, identity);
		if (symbols.exists(id))
			return;
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

	function indexStatements(fn:TypedFunction, statements:Array<TypedStatement>, resolve:String->Null<SemanticSymbolId>,
			resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>):Void {
		for (statement in statements)
			switch statement {
				case TVar(_, value, _), TReturn(value, _), TThrow(value, _), TExpression(value, _):
					indexExpression(fn, value, resolve, resolveEnumCase);
				case TAssign(identity, value, span), TCellAssign(identity, _, value, span), TCellCapturedAssign(identity, _, value, span):
					bindLocalUse(fn, identity, span);
					indexExpression(fn, value, resolve, resolveEnumCase);
				case TIncrement(identity, _, span), TCellIncrement(identity, _, _, _, span), TCellCapturedIncrement(identity, _, _, _, span):
					bindLocalUse(fn, identity, span);
				case TFieldAssign(object, name, value, span):
					bindMember(resolve, object.type, name, span);
					indexExpression(fn, object, resolve, resolveEnumCase);
					indexExpression(fn, value, resolve, resolveEnumCase);
				case TIndexAssign(object, _, value, _), TMapAssign(object, _, value, _):
					indexExpression(fn, object, resolve, resolveEnumCase);
					indexExpression(fn, value, resolve, resolveEnumCase);
				case TStaticFieldAssign(owner, name, value, span):
					bindNamed(resolve, owner + "." + name, span);
					indexExpression(fn, value, resolve, resolveEnumCase);
				case TIf(condition, yes, no, _):
					indexExpression(fn, condition, resolve, resolveEnumCase);
					indexStatements(fn, yes, resolve, resolveEnumCase);
					indexStatements(fn, no, resolve, resolveEnumCase);
				case TWhile(condition, body, _):
					indexExpression(fn, condition, resolve, resolveEnumCase);
					indexStatements(fn, body, resolve, resolveEnumCase);
				case TDoWhile(body, condition, _):
					indexStatements(fn, body, resolve, resolveEnumCase);
					indexExpression(fn, condition, resolve, resolveEnumCase);
				case TForIn(_, _, iterable, body, _):
					indexExpression(fn, iterable, resolve, resolveEnumCase);
					indexStatements(fn, body, resolve, resolveEnumCase);
				case TTry(body, catches, _):
					indexStatements(fn, body, resolve, resolveEnumCase);
					for (caught in catches)
						indexStatements(fn, caught.statements, resolve, resolveEnumCase);
				case TSwitch(value, cases, fallback, _, _):
					indexExpression(fn, value, resolve, resolveEnumCase);
					for (item in cases) {
						bindEnumCase(resolveEnumCase, item.enumName, item.constructorIndex, item.span);
						indexStatements(fn, item.statements, resolve, resolveEnumCase);
					}
					indexStatements(fn, fallback, resolve, resolveEnumCase);
				default:
			}
	}

	function indexExpression(fn:TypedFunction, expression:TypedExpression, resolve:String->Null<SemanticSymbolId>,
			resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>):Void {
		completionTypes.push({span: expression.span, type: expression.type});
		switch expression.expression {
			case TLocal(identity), TCellLocal(identity, _), TCaptured(identity), TCellCaptured(identity, _):
				var id = localId(fn, identity);
				var token = referenceToken(tokens, expression.span, sourceLocalName(identity));
				if (symbols.exists(id) && token != null)
					bind(id, token.span);
			case TNullableWrap(value), TIntToFloat(value), TIntToInt64(value), TFloatToInt(value), TToDynamic(value), TNegate(value), TNot(value),
				TThrowExpression(value), TNoReturn(value), TCast(value), TAbiCast(value), TToInterface(value, _), TArrayLength(value), TStringLength(value):
				indexExpression(fn, value, resolve, resolveEnumCase);
			case TAdd(left, right), TSub(left, right), TMul(left, right), TDiv(left, right), TMod(left, right), TBitAnd(left, right), TBitXor(left, right),
				TBitOr(left, right), TShiftLeft(left, right), TShiftRight(left, right), TUnsignedShiftRight(left, right), TLess(left, right),
				TLessEqual(left, right), TEqual(left, right), TAnd(left, right), TOr(left, right), TIndex(left, right), TMapGet(left, right),
				TStringIndexOf(left, right), TStringCharAt(left, right), TStringCharCodeAt(left, right), TArrayPush(left, right), TArrayUnshift(left, right):
				indexExpression(fn, left, resolve, resolveEnumCase);
				indexExpression(fn, right, resolve, resolveEnumCase);
			case TConditional(condition, yes, no):
				indexExpression(fn, condition, resolve, resolveEnumCase);
				indexExpression(fn, yes, resolve, resolveEnumCase);
				indexExpression(fn, no, resolve, resolveEnumCase);
			case TBlockExpression(statements, result):
				indexStatements(fn, statements, resolve, resolveEnumCase);
				indexExpression(fn, result, resolve, resolveEnumCase);
			case TField(object, name):
				bindMember(resolve, object.type, name, expression.span);
				indexExpression(fn, object, resolve, resolveEnumCase);
			case TPostfixField(object, name, _):
				bindMember(resolve, object.type, name, expression.span);
				indexExpression(fn, object, resolve, resolveEnumCase);
			case TMethodCall(object, method, arguments):
				addCall(bindNamed(resolve, method, expression.span), expression.span, method);
				indexExpression(fn, object, resolve, resolveEnumCase);
				for (argument in arguments)
					indexExpression(fn, argument, resolve, resolveEnumCase);
			case TCollectionCall(object, _, arguments):
				indexExpression(fn, object, resolve, resolveEnumCase);
				for (argument in arguments)
					indexExpression(fn, argument, resolve, resolveEnumCase);
			case TCall(name, arguments), TCNativeCall(name, arguments):
				addCall(bindNamed(resolve, name, expression.span), expression.span, name);
				for (argument in arguments)
					indexExpression(fn, argument, resolve, resolveEnumCase);
			case TFunctionRef(name):
				bindNamed(resolve, name, expression.span);
			case TMethodRef(object, name):
				bindNamed(resolve, name, expression.span);
				indexExpression(fn, object, resolve, resolveEnumCase);
			case TClassRef(name):
				bindNamed(resolve, name, expression.span);
			case TStaticField(owner, name):
				bindNamed(resolve, owner + "." + name, expression.span);
			case TPostfixStaticField(owner, name, _):
				bindNamed(resolve, owner + "." + name, expression.span);
			case TNew(name, arguments, _):
				addCall(bindNamed(resolve, name, expression.span), expression.span, name);
				for (argument in arguments)
					indexExpression(fn, argument, resolve, resolveEnumCase);
			case TEnumLiteral(name, index):
				bindEnumCase(resolveEnumCase, name, index, expression.span);
			case TEnumConstruct(name, index, arguments):
				bindEnumCase(resolveEnumCase, name, index, expression.span);
				for (argument in arguments)
					indexExpression(fn, argument, resolve, resolveEnumCase);
			case TEnumIndex(value), TEnumField(value, _, _):
				indexExpression(fn, value, resolve, resolveEnumCase);
			case TSwitchExpression(value, cases, fallback):
				indexExpression(fn, value, resolve, resolveEnumCase);
				for (item in cases) {
					bindEnumCase(resolveEnumCase, item.enumName, item.constructorIndex, item.value.span);
					indexExpression(fn, item.value, resolve, resolveEnumCase);
					if (item.guard != null)
						indexExpression(fn, item.guard, resolve, resolveEnumCase);
					indexExpression(fn, item.result, resolve, resolveEnumCase);
				}
				if (fallback != null)
					indexExpression(fn, fallback, resolve, resolveEnumCase);
			case TClosureCall(callee, arguments):
				indexExpression(fn, callee, resolve, resolveEnumCase);
				for (argument in arguments)
					indexExpression(fn, argument, resolve, resolveEnumCase);
			case TArrayLiteral(values):
				for (value in values)
					indexExpression(fn, value, resolve, resolveEnumCase);
			default:
		}
	}

	function addCall(callee:Null<SemanticSymbolId>, expression:SourceSpan, name:String):Void {
		if (currentCaller == null || callee == null)
			return;
		var token = referenceToken(tokens, expression, sourceName(name));
		var span = token == null ? expression : token.span;
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
				|| index >= tokens.length
				|| tokens[index].kind != TokenKind.LeftParen
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

	function bind(id:SemanticSymbolId, span:SourceSpan):Void {
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
		if (previous == TokenKind.Comma)
			return insideTypeArguments(index) || precededByEither(TokenKind.Extends, TokenKind.Implements, index);
		return precededBy(TokenKind.Import, index) && followedBy(TokenKind.Semicolon, index);
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

	function bindNamed(resolve:String->Null<SemanticSymbolId>, name:String, span:SourceSpan):Null<SemanticSymbolId> {
		var id = resolve(name),
			token = referenceToken(tokens, span, sourceName(name));
		if (id != null) {
			if (token != null)
				bind(id, token.span);
			recordResolvedReference(name, id);
		}
		return id;
	}

	function bindMember(resolve:String->Null<SemanticSymbolId>, type:CompilerType, name:String, span:SourceSpan):Void {
		var owner = switch type {
			case TNullable(element): memberOwner(element);
			default: memberOwner(type);
		};
		if (owner != null)
			bindNamed(resolve, owner + "." + name, span);
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
			case TInstance(_, name, _): name;
			default: null;
		};

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
