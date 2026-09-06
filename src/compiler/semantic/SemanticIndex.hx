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
import compiler.service.CancellationToken;

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

/** Revision-local declaration and resolved-local facts emitted by the compiler. */
class SemanticIndex {
	public final revision:Int;
	public final symbols:Map<String, IndexedSemanticSymbol> = [];
	public var indexingMs(default, null):Float = 0.0;

	final bindings:Array<PositionBinding> = [];
	final references:Map<String, Array<SourceSpan>> = [];
	final signatures:Map<String, SemanticSignatureInfo> = [];
	final completionLocals:Array<SemanticCompletionLocal> = [];
	final functionReceivers:Array<{span:SourceSpan, type:CompilerType}> = [];
	final completionTypes:Array<{span:SourceSpan, type:CompilerType}> = [];
	final tokens:Array<Token>;
	final module:String;
	var cancellation:Null<CancellationToken>;
	var checkpointCount:Int = 0;

	public function new(path:String, revision:Int, declarations:DeclarationIndex, tokens:Array<Token>) {
		module = ModulePath.fromFile(path);
		this.revision = revision;
		this.tokens = tokens;
		var keys = [for (key in declarations.symbols.keys()) key];
		keys.sort(Reflect.compare);
		for (key in keys) {
			var declaration = declarations.symbols.get(key),
				id = new SemanticSymbolId(module, declaration.id);
			symbols.set(id, {
				id: id,
				name: declaration.name,
				kind: declaration.kind,
				declaration: declaration.span
			});
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
	}

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
		indexStatements(fn, fn.statements, resolve, resolveEnumCase);
		bindings.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
		checkpoint();
		cancellation = null;
		indexingMs += (Sys.time() - started) * 1000.0;
	}

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
			case TNullableWrap(value), TToDynamic(value), TNegate(value), TNot(value), TThrowExpression(value), TNoReturn(value), TCast(value),
				TAbiCast(value), TToInterface(value, _), TArrayLength(value), TStringLength(value):
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
				bindNamed(resolve, method, expression.span);
				indexExpression(fn, object, resolve, resolveEnumCase);
				for (argument in arguments)
					indexExpression(fn, argument, resolve, resolveEnumCase);
			case TCollectionCall(object, _, arguments):
				indexExpression(fn, object, resolve, resolveEnumCase);
				for (argument in arguments)
					indexExpression(fn, argument, resolve, resolveEnumCase);
			case TCall(name, arguments):
				bindNamed(resolve, name, expression.span);
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
				bindNamed(resolve, name, expression.span);
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

	function bind(id:SemanticSymbolId, span:SourceSpan):Void {
		checkpoint();
		bindings.push({span: span, symbol: id});
		var locations = references.get(id);
		if (locations == null)
			references.set(id, locations = []);
		for (existing in locations)
			if (existing.start == span.start && existing.end == span.end)
				return;
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

	function bindNamed(resolve:String->Null<SemanticSymbolId>, name:String, span:SourceSpan):Void {
		var id = resolve(name),
			token = referenceToken(tokens, span, sourceName(name));
		if (id != null && token != null)
			bind(id, token.span);
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
			var token = enumReferenceToken(tokens, span, sourceName(Std.string(id)));
			if (token != null)
				bind(id, token.span);
		}
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
		for (token in tokens)
			if (token.span.start >= declaration.start
				&& token.span.end <= declaration.end
				&& token.kind == TokenKind.Identifier
				&& token.text == name)
				return token;
		return null;
	}

	static function referenceToken(tokens:Array<Token>, expression:SourceSpan, name:String):Null<Token> {
		var result:Null<Token> = null;
		for (token in tokens)
			if (token.span.start >= expression.start
				&& token.span.end <= expression.end
				&& token.kind == TokenKind.Identifier
				&& token.text == name
				&& (result == null || token.span.start < result.span.start))
				result = token;
		return result;
	}

	static function sourceName(name:String):String {
		var separator = name.lastIndexOf(".");
		return separator < 0 ? name : name.substr(separator + 1);
	}

	static function displayType(type:CompilerType):String
		return switch type {
			case TInt: "Int";
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
