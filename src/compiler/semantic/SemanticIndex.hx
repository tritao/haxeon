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

typedef SemanticCompletionContext = {
	final locals:Array<SemanticCompletionLocal>;
	final receiver:Null<CompilerType>;
	final expected:Null<CompilerType>;
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
	final tokens:Array<Token>;
	final module:String;
	var cancellation:Null<CancellationToken>;
	var currentCaller:Null<SemanticSymbolId>;
	var currentCallerName:Null<String>;
	var currentDependencyKind:SemanticDependencyKind = SemanticDependencyKind.Body;
	var checkpointCount:Int = 0;

	public function new(path:String, revision:Int, declarations:DeclarationIndex, tokens:Array<Token>) {
		module = ModulePath.fromFile(path);
		this.revision = revision;
		this.tokens = tokens;
		var keys = [for (key in declarations.symbols.keys()) key];
		keys.sort(Reflect.compare);
		for (key in keys) {
			if (!declarations.symbols.exists(key))
				throw 'Missing semantic declaration "$key"';
			var declaration = declarations.symbols.get(key),
				id = new SemanticSymbolId(module, declaration.id);
			symbols.set(id, {
				id: id,
				name: declaration.name,
				kind: declaration.kind,
				declaration: declaration.span
			});
			declarationSymbolsBySpan.set(spanKey(declaration.span), id);
			var binding = declarationToken(tokens, declaration.span, sourceName(declaration.name));
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

	function setDeclaredSignature(symbolName:String, label:String, parameters:Array<String>, result:String):Void
		for (symbol in symbols)
			if (symbol.name == symbolName)
				signatures.set(symbol.id, {label: label, parameters: parameters, result: result});

	public function indexTypedFunction(fn:TypedFunction, resolve:String->Null<SemanticSymbolId>, resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>,
			?token:CancellationToken):Void {
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
		bindings.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
		checkpoint();
		cancellation = null;
		indexingMs += (Sys.time() - started) * 1000.0;
	}

	/** Index usable local facts from a recovered syntax tree without requiring successful typing. */
	public function indexRecoveredSyntax(program:AstProgram):Void {
		for (owner in program.classes) {
			for (field in owner.fields)
				rememberRecoveredMember(owner.name, field.name, field.span);
			for (method in owner.methods)
				rememberRecoveredMember(owner.name, method.name, method.span);
		}
		for (fn in program.functions)
			indexRecoveredFunction(fn, null);
		for (owner in program.classes)
			for (fn in owner.methods)
				indexRecoveredFunction(fn, owner.name);
		for (owner in program.abstracts)
			for (fn in owner.methods)
				indexRecoveredFunction(fn, owner.name);
		bindings.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
	}

	function rememberRecoveredMember(owner:String, name:String, span:SourceSpan):Void
		for (symbol in symbols)
			if (sourceName(symbol.name) == name && symbol.declaration.start >= span.start && symbol.declaration.end <= span.end) {
				recoveredMembers.set(owner + "." + name, symbol.id);
				return;
			}

	function indexRecoveredFunction(fn:AstFunction, owner:Null<String>):Void {
		var functionKey = (owner == null ? "" : owner + ".") + fn.name;
		for (argument in fn.arguments)
			addRecoveredLocal(functionKey, argument.name, recoveredType(argument.type), argument.span, fn.span, 0);
		if (owner != null)
			functionReceivers.push({span: fn.span, type: TInstance(compiler.types.Type.NominalKind.Class, owner, [])});
		indexRecoveredStatements(functionKey, fn.statements, fn.span, 0);
		currentCaller = recoveredDeclaredSymbol(functionKey);
		indexRecoveredStatementUses(fn.statements);
		for (token in tokens)
			if (token.kind == TokenKind.Identifier && token.span.start >= fn.span.start && token.span.end <= fn.span.end)
				bindRecoveredLocal(token.text, token.span);
		currentCaller = null;
	}

	function recoveredDeclaredSymbol(name:String):Null<SemanticSymbolId> {
		for (symbol in symbols)
			if (symbol.name == name && Std.string(symbol.id).indexOf(":local:") < 0)
				return symbol.id;
		return null;
	}

	function indexRecoveredStatements(functionKey:String, statements:Array<AstStatement>, scope:SourceSpan, depth:Int):Void {
		for (statement in statements)
			switch statement {
				case UninitializedDeclaration(name, type, span):
					addRecoveredLocal(functionKey, name, recoveredType(type), span, scope, depth);
				case VarDeclaration(name, type, initializer, span):
					addRecoveredLocal(functionKey, name, type == null ? recoveredExpressionType(initializer) : recoveredType(type), span, scope, depth);
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

	function addRecoveredLocal(functionKey:String, name:String, type:CompilerType, declaration:SourceSpan, scope:SourceSpan, depth:Int):Void {
		var token = declarationToken(tokens, declaration, name);
		if (token == null)
			return;
		var id = new SemanticSymbolId(module, 'local:$functionKey:$name');
		if (!symbols.exists(id)) {
			symbols.set(id, {
				id: id,
				name: name,
				kind: DeclarationKind.Member,
				declaration: token.span
			});
			bind(id, token.span);
			declarationTypes.set(id, type);
		}
		addCompletionLocal(name, type, declaration, scope, depth);
	}

	function indexRecoveredStatementUses(statements:Array<AstStatement>):Void {
		for (statement in statements)
			switch statement {
				case VarDeclaration(_, _, value, _), Return(value, _), Throw(value, _), Expression(value, _):
					indexRecoveredExpression(value);
				case Assignment(name, value, span):
					bindRecoveredLocal(name, span);
					indexRecoveredExpression(value);
				case Increment(name, _, span):
					bindRecoveredLocal(name, span);
				case IndexAssignment(array, offset, value, _):
					indexRecoveredExpression(array);
					indexRecoveredExpression(offset);
					indexRecoveredExpression(value);
				case FieldAssignment(object, field, value, span):
					bindRecoveredMember(object, field, span);
					indexRecoveredExpression(object);
					indexRecoveredExpression(value);
				case If(predicate, yes, no, _):
					indexRecoveredExpression(predicate);
					indexRecoveredStatementUses(yes);
					indexRecoveredStatementUses(no);
				case While(predicate, body, _):
					indexRecoveredExpression(predicate);
					indexRecoveredStatementUses(body);
				case DoWhile(body, predicate, _):
					indexRecoveredStatementUses(body);
					indexRecoveredExpression(predicate);
				case ForIn(_, _, iterable, body, _):
					indexRecoveredExpression(iterable);
					indexRecoveredStatementUses(body);
				case Try(body, catches, _):
					indexRecoveredStatementUses(body);
					for (caught in catches)
						indexRecoveredStatementUses(caught.statements);
				case Switch(value, cases, fallback, _, _):
					indexRecoveredExpression(value);
					for (item in cases) {
						indexRecoveredExpression(item.value);
						if (item.guard != null)
							indexRecoveredExpression(item.guard);
						indexRecoveredStatementUses(item.statements);
					}
					indexRecoveredStatementUses(fallback);
				default:
			}
	}

	function indexRecoveredExpression(expression:AstExpression):Void {
		switch expression {
			case ErrorExpression(_):
			case Variable(name, span):
				var separator = name.indexOf(".");
				if (separator < 0)
					bindRecoveredLocal(name, span);
				else {
					var receiver = name.substring(0, separator),
						member = name.substring(name.lastIndexOf(".") + 1);
					bindRecoveredLocal(receiver, span);
					bindRecoveredMember(Variable(receiver, span), member, span);
				}
			case Member(object, name, span):
				indexRecoveredExpression(object);
				bindRecoveredMember(object, name, span);
			case Call(name, arguments, span):
				var local = bindRecoveredLocal(name, span);
				if (local == null) {
					var callee = recoveredDeclaredSymbol(name);
					if (callee != null) {
						var token = referenceToken(tokens, span, sourceName(name));
						if (token != null)
							bind(callee, token.span);
						addCall(callee, span, name);
					}
				}
				for (argument in arguments)
					indexRecoveredExpression(argument);
			case ClosureCall(callee, arguments, _):
				indexRecoveredExpression(callee);
				for (argument in arguments)
					indexRecoveredExpression(argument);
			case MethodCall(object, name, arguments, span):
				indexRecoveredExpression(object);
				var callee = bindRecoveredMember(object, name, span);
				addCall(callee, span, name);
				for (argument in arguments)
					indexRecoveredExpression(argument);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), BitAnd(left, right, _),
				BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _), UnsignedShiftRight(left, right, _),
				Less(left, right, _), LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _),
				NotEqual(left, right, _), And(left, right, _), Or(left, right, _), Index(left, right, _), Range(left, right, _):
				indexRecoveredExpression(left);
				indexRecoveredExpression(right);
			case Negate(value, _), Not(value, _), ThrowExpression(value, _), Cast(value, _, _), PostfixIncrement(value, _, _):
				indexRecoveredExpression(value);
			case Conditional(predicate, yes, no, _):
				indexRecoveredExpression(predicate);
				indexRecoveredExpression(yes);
				indexRecoveredExpression(no);
			case BlockExpression(statements, result, _):
				indexRecoveredStatementUses(statements);
				indexRecoveredExpression(result);
			case ArrayLiteral(values, _):
				for (value in values)
					indexRecoveredExpression(value);
			case ObjectLiteral(fields, _):
				for (field in fields)
					indexRecoveredExpression(field.value);
			case MapLiteral(entries, _):
				for (entry in entries) {
					indexRecoveredExpression(entry.key);
					indexRecoveredExpression(entry.value);
				}
			case New(_, arguments, _), NewGeneric(_, _, arguments, _):
				for (argument in arguments)
					indexRecoveredExpression(argument);
			case NewArray(_, length, _):
				indexRecoveredExpression(length);
			case Lambda(_, body, _):
				indexRecoveredStatementUses(body);
			case SwitchExpression(value, cases, fallback, _):
				indexRecoveredExpression(value);
				for (item in cases) {
					indexRecoveredExpression(item.value);
					if (item.guard != null)
						indexRecoveredExpression(item.guard);
					indexRecoveredExpression(item.result);
				}
				if (fallback != null)
					indexRecoveredExpression(fallback);
			default:
		}
	}

	function bindRecoveredLocal(name:String, span:SourceSpan):Null<SemanticSymbolId> {
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
		if (id == null)
			return null;
		var token = referenceToken(tokens, span, name);
		if (token != null)
			bind(id, token.span);
		return id;
	}

	function recoveredExpressionBindingType(expression:AstExpression):CompilerType
		return switch expression {
			case Variable(name, span): var id = bindRecoveredLocal(name,
					span); id == null || !declarationTypes.exists(id) ? TDynamic : declarationTypes.get(id);
			case New(name, _, _), NewGeneric(name, _, _, _): TInstance(compiler.types.Type.NominalKind.Class, name, []);
			default: recoveredExpressionType(expression);
		};

	static function recoveredExpressionType(expression:AstExpression):CompilerType
		return switch expression {
			case IntegerLiteral(_, _): TInt;
			case FloatLiteral(_, _): TFloat;
			case StringLiteral(_, _): TString;
			case BoolLiteral(_, _): TBool;
			case ArrayLiteral(_, _): TArray(TDynamic);
			case MapLiteral(_, _): TMap(TDynamic, TDynamic);
			case New(name, _, _), NewGeneric(name, _, _, _): TInstance(compiler.types.Type.NominalKind.Class, name, []);
			default: TDynamic;
		};

	static function recoveredType(type:AstType):CompilerType
		return switch type {
			case IntType: TInt;
			case BoolType: TBool;
			case FloatType: TFloat;
			case StringType: TString;
			case VoidType: TVoid;
			case ArrayType(element): TArray(recoveredType(element));
			case MapType(key, value): TMap(recoveredType(key), recoveredType(value));
			case NullableType(element): TNullable(recoveredType(element));
			case NamedType(name), AppliedType(name, _): TInstance(compiler.types.Type.NominalKind.Class, name, []);
			default: TDynamic;
		};

	public function symbolIdAt(position:Int):Null<SemanticSymbolId> {
		for (binding in bindings)
			if (position >= binding.span.start && position <= binding.span.end)
				return binding.symbol;
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

	public function completionContext(position:Int, ?qualifier:String):SemanticCompletionContext {
		var visible:Map<String, SemanticCompletionLocal> = [];
		for (local in completionLocals)
			if (position >= local.declaration.start && position <= local.scope.end) {
				var existing = visible.get(local.name);
				if (existing == null
					|| local.depth > existing.depth
					|| (local.depth == existing.depth && local.declaration.start > existing.declaration.start))
					visible.set(local.name, local);
			}
		var locals = [for (local in visible) local];
		locals.sort(function(left, right) return Reflect.compare(left.name, right.name));
		var receiver:Null<CompilerType> = null;
		if (qualifier != null) {
			if (qualifier == "this")
				for (candidate in functionReceivers)
					if (position >= candidate.span.start && position <= candidate.span.end)
						receiver = candidate.type;
			if (receiver == null)
				for (local in locals)
					if (local.name == qualifier)
						receiver = local.type;
		}
		var expected:Null<CompilerType> = null, expectedWidth = 0x3fffffff;
		for (candidate in completionTypes)
			if (position >= candidate.span.start && position <= candidate.span.end) {
				var width = candidate.span.end - candidate.span.start;
				if (width < expectedWidth) {
					expected = candidate.type;
					expectedWidth = width;
				}
			}
		return {locals: locals, receiver: receiver, expected: expected};
	}

	public function typeAt(position:Int):Null<CompilerType> {
		var result:Null<CompilerType> = null, width = 0x3fffffff;
		for (candidate in completionTypes)
			if (position >= candidate.span.start && position <= candidate.span.end && candidate.span.end - candidate.span.start < width) {
				result = candidate.type;
				width = candidate.span.end - candidate.span.start;
			}
		for (local in completionLocals)
			if (position >= local.declaration.start && position <= local.declaration.end)
				return local.type;
		if (result != null)
			return result;
		var symbol = symbolIdAt(position);
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
		for (index in 0...tokens.length) {
			var token = tokens[index];
			if (token.span.start < fn.span.start
				|| token.span.end > fn.span.end
				|| token.kind != TokenKind.Identifier
				|| index + 1 >= tokens.length
				|| tokens[index + 1].kind != TokenKind.LeftParen
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
