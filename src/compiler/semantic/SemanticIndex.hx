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

/** Revision-local declaration and resolved-local facts emitted by the compiler. */
class SemanticIndex {
	public final symbols:Map<String, IndexedSemanticSymbol> = [];

	final bindings:Array<PositionBinding> = [];
	final references:Map<String, Array<SourceSpan>> = [];
	final tokens:Array<Token>;
	final module:String;

	public function new(path:String, declarations:DeclarationIndex, tokens:Array<Token>) {
		module = ModulePath.fromFile(path);
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
	}

	public function indexTypedFunction(fn:TypedFunction, resolve:String->Null<SemanticSymbolId>):Void {
		for (argument in fn.arguments)
			declareLocal(fn, argument.name, fn.span);
		declareLocals(fn, fn.statements);
		indexStatements(fn, fn.statements, resolve);
		bindings.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
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

	public function locations(id:SemanticSymbolId):Array<SourceSpan> {
		var result = references.get(id);
		return result == null ? [] : result.copy();
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

	function indexStatements(fn:TypedFunction, statements:Array<TypedStatement>, resolve:String->Null<SemanticSymbolId>):Void {
		for (statement in statements)
			switch statement {
				case TVar(_, value, _), TReturn(value, _), TThrow(value, _), TExpression(value, _):
					indexExpression(fn, value, resolve);
				case TAssign(identity, value, span), TCellAssign(identity, _, value, span), TCellCapturedAssign(identity, _, value, span):
					bindLocalUse(fn, identity, span);
					indexExpression(fn, value, resolve);
				case TIncrement(identity, _, span), TCellIncrement(identity, _, _, _, span), TCellCapturedIncrement(identity, _, _, _, span):
					bindLocalUse(fn, identity, span);
				case TFieldAssign(object, name, value, span):
					bindMember(resolve, object.type, name, span);
					indexExpression(fn, object, resolve);
					indexExpression(fn, value, resolve);
				case TIndexAssign(object, _, value, _), TMapAssign(object, _, value, _):
					indexExpression(fn, object, resolve);
					indexExpression(fn, value, resolve);
				case TStaticFieldAssign(owner, name, value, span):
					bindNamed(resolve, owner + "." + name, span);
					indexExpression(fn, value, resolve);
				case TIf(condition, yes, no, _):
					indexExpression(fn, condition, resolve);
					indexStatements(fn, yes, resolve);
					indexStatements(fn, no, resolve);
				case TWhile(condition, body, _):
					indexExpression(fn, condition, resolve);
					indexStatements(fn, body, resolve);
				case TDoWhile(body, condition, _):
					indexStatements(fn, body, resolve);
					indexExpression(fn, condition, resolve);
				case TForIn(_, _, iterable, body, _):
					indexExpression(fn, iterable, resolve);
					indexStatements(fn, body, resolve);
				case TTry(body, catches, _):
					indexStatements(fn, body, resolve);
					for (caught in catches)
						indexStatements(fn, caught.statements, resolve);
				case TSwitch(value, cases, fallback, _, _):
					indexExpression(fn, value, resolve);
					for (item in cases)
						indexStatements(fn, item.statements, resolve);
					indexStatements(fn, fallback, resolve);
				default:
			}
	}

	function indexExpression(fn:TypedFunction, expression:TypedExpression, resolve:String->Null<SemanticSymbolId>):Void {
		switch expression.expression {
			case TLocal(identity), TCellLocal(identity, _), TCaptured(identity), TCellCaptured(identity, _):
				var id = localId(fn, identity);
				var token = referenceToken(tokens, expression.span, sourceLocalName(identity));
				if (symbols.exists(id) && token != null)
					bind(id, token.span);
			case TNullableWrap(value), TToDynamic(value), TNegate(value), TNot(value), TThrowExpression(value), TNoReturn(value), TCast(value),
				TAbiCast(value), TToInterface(value, _), TArrayLength(value), TStringLength(value):
				indexExpression(fn, value, resolve);
			case TAdd(left, right), TSub(left, right), TMul(left, right), TDiv(left, right), TMod(left, right), TBitAnd(left, right), TBitXor(left, right),
				TBitOr(left, right), TShiftLeft(left, right), TShiftRight(left, right), TUnsignedShiftRight(left, right), TLess(left, right),
				TLessEqual(left, right), TEqual(left, right), TAnd(left, right), TOr(left, right), TIndex(left, right), TMapGet(left, right),
				TStringIndexOf(left, right), TStringCharAt(left, right), TStringCharCodeAt(left, right), TArrayPush(left, right), TArrayUnshift(left, right):
				indexExpression(fn, left, resolve);
				indexExpression(fn, right, resolve);
			case TConditional(condition, yes, no):
				indexExpression(fn, condition, resolve);
				indexExpression(fn, yes, resolve);
				indexExpression(fn, no, resolve);
			case TBlockExpression(statements, result):
				indexStatements(fn, statements, resolve);
				indexExpression(fn, result, resolve);
			case TField(object, name):
				bindMember(resolve, object.type, name, expression.span);
				indexExpression(fn, object, resolve);
			case TPostfixField(object, name, _):
				bindMember(resolve, object.type, name, expression.span);
				indexExpression(fn, object, resolve);
			case TMethodCall(object, method, arguments):
				bindNamed(resolve, method, expression.span);
				indexExpression(fn, object, resolve);
				for (argument in arguments)
					indexExpression(fn, argument, resolve);
			case TCollectionCall(object, _, arguments):
				indexExpression(fn, object, resolve);
				for (argument in arguments)
					indexExpression(fn, argument, resolve);
			case TCall(name, arguments):
				bindNamed(resolve, name, expression.span);
				for (argument in arguments)
					indexExpression(fn, argument, resolve);
			case TFunctionRef(name):
				bindNamed(resolve, name, expression.span);
			case TClassRef(name):
				bindNamed(resolve, name, expression.span);
			case TStaticField(owner, name):
				bindNamed(resolve, owner + "." + name, expression.span);
			case TPostfixStaticField(owner, name, _):
				bindNamed(resolve, owner + "." + name, expression.span);
			case TNew(name, arguments, _):
				bindNamed(resolve, name, expression.span);
				for (argument in arguments)
					indexExpression(fn, argument, resolve);
			case TEnumConstruct(_, _, arguments):
				for (argument in arguments)
					indexExpression(fn, argument, resolve);
			case TClosureCall(callee, arguments):
				indexExpression(fn, callee, resolve);
				for (argument in arguments)
					indexExpression(fn, argument, resolve);
			case TArrayLiteral(values):
				for (value in values)
					indexExpression(fn, value, resolve);
			default:
		}
	}

	function bind(id:SemanticSymbolId, span:SourceSpan):Void {
		bindings.push({span: span, symbol: id});
		var locations = references.get(id);
		if (locations == null)
			references.set(id, locations = []);
		for (existing in locations)
			if (existing.start == span.start && existing.end == span.end)
				return;
		locations.push(span);
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
}
