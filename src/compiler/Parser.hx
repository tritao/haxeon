package compiler;

import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstClass;
import compiler.Ast.AstInterface;
import compiler.Ast.AstTypeAlias;
import compiler.Ast.AstEnum;
import compiler.Ast.AstProgram;
import compiler.Ast.AstStatement;
import compiler.Ast.AstType;
import compiler.Source.SourceSpan;
import compiler.Token.TokenKind;
import compiler.Diagnostic.CompileError;

class Parser {
	final tokens:Array<Token>;
	var position:Int = 0;

	public function new(tokens:Array<Token>) {
		this.tokens = tokens;
	}

	public function parseProgram():AstProgram {
		var packageName:Null<String> = null, imports = [];
		if (match(TokenKind.Package)) {
			packageName = parseQualifiedName();
			consume(TokenKind.Semicolon);
		}
		while (match(TokenKind.Import)) {
			imports.push(parseQualifiedName());
			consume(TokenKind.Semicolon);
		}
		var functions = [], aliases:Array<AstTypeAlias> = [], enums:Array<AstEnum> = [], interfaces:Array<AstInterface> = [], classes = [];
		while (!check(TokenKind.Eof)) {
			if (match(TokenKind.Typedef))
				aliases.push(parseTypeAlias(previous().span));
			else if (match(TokenKind.Enum))
				enums.push(parseEnum(previous().span));
			else if (check(TokenKind.Interface))
				interfaces.push(parseInterface());
			else if (check(TokenKind.Class))
				classes.push(parseClass());
			else
				functions.push(parseFunction(false));
		}
		return {
			packageName: packageName,
			imports: imports,
			aliases: aliases,
			enums: enums,
			interfaces: interfaces,
			classes: classes,
			functions: functions
		};
	}

	function parseTypeAlias(start:SourceSpan):AstTypeAlias {
		var name = consume(TokenKind.Identifier).text;
		consume(TokenKind.Assign);
		var type = parseType(), end = consume(TokenKind.Semicolon).span;
		return {name: name, type: type, span: start.merge(end)};
	}

	function parseEnum(start:SourceSpan):AstEnum {
		var name = consume(TokenKind.Identifier).text, cases = [];
		consume(TokenKind.LeftBrace);
		while (!check(TokenKind.RightBrace)) {
			var caseToken = consume(TokenKind.Identifier);
			cases.push({name: caseToken.text, span: caseToken.span});
			consume(TokenKind.Semicolon);
		}
		var end = consume(TokenKind.RightBrace).span;
		return {name: name, cases: cases, span: start.merge(end)};
	}

	function parseQualifiedName():String {
		var name = consume(TokenKind.Identifier).text;
		while (match(TokenKind.Dot))
			name += "." + consume(TokenKind.Identifier).text;
		return name;
	}

	function parseFunction(allowMissingReturn:Bool):AstFunction {
		var start = consume(TokenKind.Function).span,
			name = check(TokenKind.New) ? advance().text : consume(TokenKind.Identifier).text;
		return parseFunctionBody(start, name, allowMissingReturn, false);
	}

	function parseFunctionBody(start:SourceSpan, name:String, allowMissingReturn:Bool, isStatic:Bool = false):AstFunction {
		consume(TokenKind.LeftParen);
		var arguments = [];
		if (!check(TokenKind.RightParen)) {
			do {
				var argumentName = consume(TokenKind.Identifier).text;
				consume(TokenKind.Colon);
				arguments.push({name: argumentName, type: parseType(), span: previous().span});
			} while (match(TokenKind.Comma));
		}
		consume(TokenKind.RightParen);
		var result = match(TokenKind.Colon) ? parseType() : allowMissingReturn
			&& name == "new" ? VoidType : failType("Expected return type");
		consume(TokenKind.LeftBrace);
		var statements = [];
		while (!check(TokenKind.RightBrace))
			statements.push(parseStatement());
		var end = consume(TokenKind.RightBrace).span;
		return {
			name: name,
			isStatic: isStatic,
			arguments: arguments,
			result: result,
			statements: statements,
			span: start.merge(end)
		};
	}

	function parseClass():AstClass {
		var start = consume(TokenKind.Class).span,
			name = consume(TokenKind.Identifier).text,
			base:Null<String> = null,
			interfaces = [];
		if (match(TokenKind.Extends))
			base = parseQualifiedName();
		if (match(TokenKind.Implements)) {
			interfaces.push(parseQualifiedName());
			while (match(TokenKind.Comma))
				interfaces.push(parseQualifiedName());
		}
		consume(TokenKind.LeftBrace);
		var fields = [], methods = [];
		while (!check(TokenKind.RightBrace)) {
			var isStatic = false, isFinal = false;
			while (true) {
				switch current().kind {
					case TokenKind.Public, TokenKind.Private:
						advance();
					case TokenKind.Static:
						advance();
						isStatic = true;
					case TokenKind.Final:
						advance();
						isFinal = true;
					default:
						break;
				}
				if (current().kind != TokenKind.Public && current().kind != TokenKind.Private && current().kind != TokenKind.Static
					&& current().kind != TokenKind.Final)
					break;
			}
			if (match(TokenKind.Function)) {
				var functionStart = previous().span,
					methodName = check(TokenKind.New) ? advance().text : consume(TokenKind.Identifier).text;
				methods.push(parseFunctionBody(functionStart, methodName, true, isStatic));
			} else {
				var fieldStart = current().span;
				match(TokenKind.Var);
				var fieldName = consume(TokenKind.Identifier).text;
				consume(TokenKind.Colon);
				var fieldType = parseType(),
					end = consume(TokenKind.Semicolon).span;
				fields.push({
					name: fieldName,
					type: fieldType,
					isStatic: isStatic,
					isFinal: isFinal,
					span: fieldStart.merge(end)
				});
			}
		}
		var end = consume(TokenKind.RightBrace).span;
		return {
			name: name,
			base: base,
			interfaces: interfaces,
			fields: fields,
			methods: methods,
			span: start.merge(end)
		};
	}

	function parseInterface():AstInterface {
		var start = consume(TokenKind.Interface).span, name = consume(TokenKind.Identifier).text, bases = [];
		if (match(TokenKind.Extends)) {
			bases.push(parseQualifiedName());
			while (match(TokenKind.Comma))
				bases.push(parseQualifiedName());
		}
		consume(TokenKind.LeftBrace);
		var methods = [];
		while (!check(TokenKind.RightBrace)) {
			var methodStart = consume(TokenKind.Function).span,
				methodName = consume(TokenKind.Identifier).text;
			consume(TokenKind.LeftParen);
			var arguments = [];
			if (!check(TokenKind.RightParen))
				do {
					var argumentName = consume(TokenKind.Identifier).text;
					consume(TokenKind.Colon);
					arguments.push({name: argumentName, type: parseType(), span: previous().span});
				} while (match(TokenKind.Comma));
			consume(TokenKind.RightParen);
			var result = match(TokenKind.Colon) ? parseType() : failType("Interface methods require a return type"),
				end = consume(TokenKind.Semicolon).span;
			methods.push({
				name: methodName,
				isStatic: false,
				arguments: arguments,
				result: result,
				statements: [],
				span: methodStart.merge(end)
			});
		}
		var end = consume(TokenKind.RightBrace).span;
		return {
			name: name,
			bases: bases,
			methods: methods,
			span: start.merge(end)
		};
	}

	function parseStatement():AstStatement {
		if (match(TokenKind.Var)) {
			var start = previous().span;
			var name = consume(TokenKind.Identifier).text;
			var type = match(TokenKind.Colon) ? parseType() : null;
			consume(TokenKind.Assign);
			var initializer = parseExpression();
			var end = consume(TokenKind.Semicolon).span;
			return VarDeclaration(name, type, initializer, start.merge(end));
		}
		if (match(TokenKind.Return)) {
			var start = previous().span;
			if (check(TokenKind.Semicolon))
				return ReturnVoid(start.merge(consume(TokenKind.Semicolon).span));
			var expression = parseExpression();
			var end = consume(TokenKind.Semicolon).span;
			return Return(expression, start.merge(end));
		}
		if (check(TokenKind.Identifier) || check(TokenKind.This)) {
			var saved = position, target = parseExpression();
			if (match(TokenKind.Assign)) {
				var value = parseExpression(),
					end = consume(TokenKind.Semicolon).span,
					assignment = switch target {
						case Variable(name, _): Assignment(name, value, expressionSpan(target).merge(end));
						case Index(array, offset, _): IndexAssignment(array, offset, value, expressionSpan(target).merge(end));
						default:
							throw new CompileError(new Diagnostic("E0002", "Assignment target must be a variable, field, or array element",
								expressionSpan(target)));
					};
				return assignment;
			}
			position = saved;
		}
		if (match(TokenKind.If)) {
			var start = previous().span;
			consume(TokenKind.LeftParen);
			var condition = parseExpression();
			consume(TokenKind.RightParen);
			var thenBranch = parseStatementOrBlock();
			var elseBranch = match(TokenKind.Else) ? parseStatementOrBlock() : [];
			var end = elseBranch.length > 0 ? statementSpan(elseBranch[elseBranch.length - 1]) : statementSpan(thenBranch[thenBranch.length - 1]);
			return If(condition, thenBranch, elseBranch, start.merge(end));
		}
		if (match(TokenKind.While)) {
			var start = previous().span;
			consume(TokenKind.LeftParen);
			var condition = parseExpression();
			consume(TokenKind.RightParen);
			var body = parseStatementOrBlock();
			var end = statementSpan(body[body.length - 1]);
			return While(condition, body, start.merge(end));
		}
		if (match(TokenKind.For)) {
			var start = previous().span;
			consume(TokenKind.LeftParen);
			match(TokenKind.Var);
			var name = consume(TokenKind.Identifier).text;
			consume(TokenKind.In);
			var iterable = parseExpression();
			consume(TokenKind.RightParen);
			var body = parseStatementOrBlock(),
				end = statementSpan(body[body.length - 1]);
			return ForIn(name, iterable, body, start.merge(end));
		}
		var expression = parseExpression(),
			end = consume(TokenKind.Semicolon).span;
		return Expression(expression, expressionSpan(expression).merge(end));
	}

	function parseExpression():AstExpression {
		var expression = parseAdditive();
		if (check(TokenKind.Less) || check(TokenKind.LessEqual) || check(TokenKind.EqualEqual)) {
			var operation = advance().kind;
			var right = parseAdditive();
			var span = expressionSpan(expression).merge(expressionSpan(right));
			expression = switch operation {
				case TokenKind.Less: Less(expression, right, span);
				case TokenKind.LessEqual: LessEqual(expression, right, span);
				default: Equal(expression, right, span);
			}
		}
		return expression;
	}

	function parseAdditive():AstExpression {
		var expression = parseMultiplicative();
		while (check(TokenKind.Plus) || check(TokenKind.Minus)) {
			var operation = advance().kind;
			var right = parseMultiplicative();
			var span = expressionSpan(expression).merge(expressionSpan(right));
			expression = operation == TokenKind.Plus ? Add(expression, right, span) : Sub(expression, right, span);
		}
		return expression;
	}

	function parseMultiplicative():AstExpression {
		var expression = parsePrimary();
		while (check(TokenKind.Star) || check(TokenKind.Slash)) {
			var operation = advance().kind,
				right = parsePrimary(),
				span = expressionSpan(expression).merge(expressionSpan(right));
			expression = operation == TokenKind.Star ? Mul(expression, right, span) : Div(expression, right, span);
		}
		return expression;
	}

	function parsePrimary():AstExpression {
		if (match(TokenKind.Integer))
			return IntegerLiteral(Std.parseInt(previous().text), previous().span);
		if (match(TokenKind.Float))
			return FloatLiteral(Std.parseFloat(previous().text), previous().span);
		if (match(TokenKind.StringLiteral))
			return StringLiteral(decodeString(previous().text), previous().span);
		if (match(TokenKind.BoolTrue))
			return BoolLiteral(true, previous().span);
		if (match(TokenKind.BoolFalse))
			return BoolLiteral(false, previous().span);
		if (check(TokenKind.Identifier) && current().text == "null") {
			var nullToken = advance();
			return NullLiteral(nullToken.span);
		}
		if (match(TokenKind.New)) {
			var start = previous().span;
			if (check(TokenKind.Identifier) && current().text == "Array") {
				advance();
				consume(TokenKind.Less);
				var element = parseType();
				consume(TokenKind.Greater);
				consume(TokenKind.LeftParen);
				var length = parseExpression();
				var end = consume(TokenKind.RightParen).span;
				return parsePostfix(NewArray(element, length, start.merge(end)));
			}
			var typeName = parseQualifiedName();
			consume(TokenKind.LeftParen);
			var arguments = [];
			if (!check(TokenKind.RightParen)) {
				do
					arguments.push(parseExpression()) while (match(TokenKind.Comma));
			}
			var end = consume(TokenKind.RightParen).span;
			return parsePostfix(New(typeName, arguments, start.merge(end)));
		}
		if (check(TokenKind.LeftParen)) {
			var saved = position,
				start = current().span,
				lambdaStart = position + 1,
				isLambda = lambdaStart < tokens.length
					&& ((tokens[lambdaStart].kind == TokenKind.RightParen
						&& lambdaStart + 1 < tokens.length
						&& tokens[lambdaStart + 1].kind == TokenKind.Arrow)
						|| (tokens[lambdaStart].kind == TokenKind.Identifier
							&& lambdaStart + 1 < tokens.length
							&& tokens[lambdaStart + 1].kind == TokenKind.Colon));
			if (!isLambda) {
				advance();
				var grouped = parseExpression();
				consume(TokenKind.RightParen);
				return parsePostfix(grouped);
			}
			advance();
			var arguments = [];
			if (!check(TokenKind.RightParen)) {
				do {
					var argumentStart = current().span,
						argumentName = consume(TokenKind.Identifier).text;
					consume(TokenKind.Colon);
					arguments.push({name: argumentName, type: parseType(), span: argumentStart.merge(previous().span)});
				} while (match(TokenKind.Comma));
			}
			consume(TokenKind.RightParen);
			if (match(TokenKind.Arrow)) {
				var body = parseStatementOrBlock();
				return Lambda(arguments, body, start.merge(body.length == 0 ? previous().span : statementSpan(body[body.length - 1])));
			}
			position = saved;
		}
		if (match(TokenKind.This)) {
			var start = previous().span, name = "this";
			while (match(TokenKind.Dot))
				name += "." + consume(TokenKind.Identifier).text;
			var expression:AstExpression = Variable(name, start);
			return parsePostfix(expression);
		}
		if (match(TokenKind.Identifier)) {
			var name = previous().text;
			var start = previous().span;
			while (match(TokenKind.Dot)) {
				name += "." + consume(TokenKind.Identifier).text;
			}
			var expression:AstExpression = Variable(name, start);
			if (match(TokenKind.LeftParen)) {
				var arguments = [];
				if (!check(TokenKind.RightParen)) {
					do
						arguments.push(parseExpression()) while (match(TokenKind.Comma));
				}
				var end = consume(TokenKind.RightParen).span;
				expression = Call(name, arguments, start.merge(end));
			}
			return parsePostfix(expression);
		}
		if (match(TokenKind.LeftParen)) {
			var expression = parseExpression();
			consume(TokenKind.RightParen);
			return parsePostfix(expression);
		}
		fail(current(), "Expected expression");
		return null;
	}

	function parsePostfix(expression:AstExpression):AstExpression {
		while (true) {
			if (match(TokenKind.LeftBracket)) {
				var offset = parseExpression(),
					end = consume(TokenKind.RightBracket).span;
				expression = Index(expression, offset, expressionSpan(expression).merge(end));
				continue;
			}
			if (match(TokenKind.Dot)) {
				var nameToken = consume(TokenKind.Identifier),
					name = nameToken.text;
				if (match(TokenKind.LeftParen)) {
					var arguments = [];
					if (!check(TokenKind.RightParen)) {
						do
							arguments.push(parseExpression()) while (match(TokenKind.Comma));
					}
					var end = consume(TokenKind.RightParen).span;
					expression = MethodCall(expression, name, arguments, expressionSpan(expression).merge(end));
				} else
					expression = Member(expression, name, expressionSpan(expression).merge(nameToken.span));
				continue;
			}
			break;
		}
		return expression;
	}

	function parseType():AstType {
		if (match(TokenKind.LeftParen)) {
			var arguments = [];
			if (!check(TokenKind.RightParen)) {
				do
					arguments.push(parseType()) while (match(TokenKind.Comma));
			}
			consume(TokenKind.RightParen);
			consume(TokenKind.Arrow);
			return FunctionType(arguments, parseType());
		}
		var atomic = parseAtomicType();
		if (match(TokenKind.Arrow))
			return FunctionType(switch atomic {
				case VoidType: [];
				default: [atomic];
			}, parseType());
		return atomic;
	}

	function parseAtomicType():AstType {
		if (match(TokenKind.TypeInt))
			return IntType;
		if (match(TokenKind.TypeBool))
			return BoolType;
		if (match(TokenKind.TypeFloat))
			return FloatType;
		if (match(TokenKind.TypeString))
			return StringType;
		if (match(TokenKind.Void))
			return VoidType;
		if (check(TokenKind.Identifier))
			if (current().text == "Array") {
				advance();
				consume(TokenKind.Less);
				var element = parseType();
				consume(TokenKind.Greater);
				return ArrayType(element);
			} else if (current().text == "Null") {
				advance();
				consume(TokenKind.Less);
				var element = parseType();
				consume(TokenKind.Greater);
				return NullableType(element);
			}
		return NamedType(parseQualifiedName());
		fail(current(), 'Expected type, got ${current().kind}');
		return null;
	}

	function failType(message:String):AstType {
		fail(current(), message);
		return null;
	}

	function parseStatementOrBlock():Array<AstStatement> {
		if (!match(TokenKind.LeftBrace))
			return [parseStatement()];
		var statements = [];
		while (!check(TokenKind.RightBrace))
			statements.push(parseStatement());
		consume(TokenKind.RightBrace);
		return statements;
	}

	function match(kind:TokenKind):Bool {
		if (!check(kind))
			return false;
		advance();
		return true;
	}

	function consume(kind:TokenKind):Token {
		if (check(kind))
			return advance();
		fail(current(), 'Expected $kind, got ${current().kind}');
		return null;
	}

	function check(kind:TokenKind):Bool
		return current().kind == kind;

	function advance():Token
		return tokens[position++];

	function current():Token
		return tokens[position];

	function previous():Token
		return tokens[position - 1];

	function fail(token:Token, message:String):Void
		throw new CompileError(new Diagnostic("E0002", message, token.span));

	static function expressionSpan(expression:AstExpression)
		return switch expression {
			case IntegerLiteral(_, span), FloatLiteral(_, span), StringLiteral(_, span), BoolLiteral(_, span), NullLiteral(span), Variable(_, span),
				Member(_, _, span), Add(_, _, span), Sub(_, _, span), Mul(_, _, span), Div(_, _, span), Less(_, _, span), LessEqual(_, _, span),
				Equal(_, _,
					span), Call(_, _, span), MethodCall(_, _, _, span), New(_, _, span), NewArray(_, _, span), Index(_, _, span), Lambda(_, _, span): span;
		}

	static function decodeString(text:String):String {
		var out = new StringBuf(), i = 1;
		while (i < text.length - 1) {
			var c = text.charAt(i++);
			if (c != "\\") {
				out.add(c);
				continue;
			}
			var escaped = text.charAt(i++);
			out.add(switch escaped {
				case "n": "\n";
				case "r": "\r";
				case "t": "\t";
				case "\"": "\"";
				case "\\": "\\";
				default: escaped;
			});
		}
		return out.toString();
	}

	static function statementSpan(statement:AstStatement)
		return switch statement {
			case VarDeclaration(_, _, _, span), Assignment(_, _, span), IndexAssignment(_, _, _, span), Return(_, span), ReturnVoid(span), If(_, _, _, span),
				While(_, _, span), ForIn(_, _, _, span), Expression(_, span): span;
		}
}
