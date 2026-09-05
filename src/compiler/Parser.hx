package compiler;

import compiler.Ast.AstExpression;
import compiler.Ast.AstFieldAccess;
import compiler.Ast.AstFunction;
import compiler.Ast.AstClass;
import compiler.Ast.AstInterface;
import compiler.Ast.AstTypeAlias;
import compiler.Ast.AstEnum;
import compiler.Ast.AstEnumAbstract;
import compiler.Ast.AstAbstract;
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
		var packageName:Null<String> = null, imports = [], importAliases:Map<String, String> = [];
		if (match(TokenKind.Package)) {
			packageName = parseQualifiedName();
			consume(TokenKind.Semicolon);
		}
		while (match(TokenKind.Import)) {
			var path = parseQualifiedName();
			imports.push(path);
			if (check(TokenKind.Identifier) && current().text == "as") {
				advance();
				var alias = consume(TokenKind.Identifier).text;
				if (importAliases.exists(alias))
					fail(previous(), 'Duplicate import alias "$alias"');
				importAliases.set(alias, path);
			}
			consume(TokenKind.Semicolon);
		}
		var functions = [], aliases:Array<AstTypeAlias> = [], enums:Array<AstEnum> = [], enumAbstracts:Array<AstEnumAbstract> = [],
			abstracts:Array<AstAbstract> = [], interfaces:Array<AstInterface> = [], classes = [];
		while (!check(TokenKind.Eof)) {
			var visibility = match(TokenKind.Private) ? previous() : match(TokenKind.Public) ? previous() : null;
			if (match(TokenKind.Typedef))
				aliases.push(parseTypeAlias(visibility == null ? previous()
					.span : visibility.span, visibility != null && visibility.kind == TokenKind.Private));
			else if (visibility != null)
				fail(current(), "Top-level visibility modifier is not supported for this declaration");
			else if (match(TokenKind.Enum)) {
				var start = previous().span;
				if (check(TokenKind.Identifier) && current().text == "abstract") {
					advance();
					enumAbstracts.push(parseEnumAbstract(start));
				} else
					enums.push(parseEnum(start));
			} else if (check(TokenKind.Interface))
				interfaces.push(parseInterface());
			else if (check(TokenKind.Class))
				classes.push(parseClass());
			else if (check(TokenKind.Identifier) && current().text == "abstract") {
				var start = advance().span;
				abstracts.push(parseAbstract(start));
			} else
				functions.push(parseFunction(false));
		}
		return {
			packageName: packageName,
			imports: imports,
			importAliases: importAliases,
			aliases: aliases,
			enums: enums,
			enumAbstracts: enumAbstracts,
			abstracts: abstracts,
			interfaces: interfaces,
			classes: classes,
			functions: functions
		};
	}

	function parseAbstract(start:SourceSpan):AstAbstract {
		var name = consume(TokenKind.Identifier).text;
		consume(TokenKind.LeftParen);
		var underlying = parseType();
		consume(TokenKind.RightParen);
		var fromTypes = [], toTypes = [];
		while (!check(TokenKind.LeftBrace)) {
			var conversion = consume(TokenKind.Identifier);
			if (conversion.text != "from" && conversion.text != "to")
				fail(conversion, 'Expected "from" or "to"');
			var conversionType = parseType();
			if (conversion.text == "from")
				fromTypes.push(conversionType);
			else
				toTypes.push(conversionType);
		}
		consume(TokenKind.LeftBrace);
		var methods = [];
		while (!check(TokenKind.RightBrace)) {
			var isStatic = false;
			while (check(TokenKind.Public) || check(TokenKind.Private) || check(TokenKind.Inline) || check(TokenKind.Static)) {
				if (match(TokenKind.Static))
					isStatic = true;
				else
					advance();
			}
			var functionStart = consume(TokenKind.Function).span,
				methodName = check(TokenKind.New) ? advance().text : consume(TokenKind.Identifier).text;
			methods.push(parseFunctionBody(functionStart, methodName, true, isStatic));
		}
		var end = consume(TokenKind.RightBrace).span;
		return {
			name: name,
			underlying: underlying,
			fromTypes: fromTypes,
			toTypes: toTypes,
			methods: methods,
			span: start.merge(end)
		};
	}

	function parseEnumAbstract(start:SourceSpan):AstEnumAbstract {
		var name = consume(TokenKind.Identifier).text;
		consume(TokenKind.LeftParen);
		var underlying = parseType();
		consume(TokenKind.RightParen);
		var fromTypes = [], toTypes = [];
		while (!check(TokenKind.LeftBrace)) {
			var conversion = consume(TokenKind.Identifier);
			if (conversion.text != "from" && conversion.text != "to")
				fail(conversion, 'Expected "from" or "to"');
			var conversionType = parseType();
			if (conversion.text == "from")
				fromTypes.push(conversionType);
			else
				toTypes.push(conversionType);
		}
		consume(TokenKind.LeftBrace);
		var values = [];
		while (!check(TokenKind.RightBrace)) {
			match(TokenKind.Var);
			var valueName = consumeName();
			consume(TokenKind.Assign);
			var value = parseExpression(),
				end = consume(TokenKind.Semicolon).span;
			values.push({name: valueName.text, value: value, span: valueName.span.merge(end)});
		}
		var end = consume(TokenKind.RightBrace).span;
		return {
			name: name,
			underlying: underlying,
			fromTypes: fromTypes,
			toTypes: toTypes,
			values: values,
			span: start.merge(end)
		};
	}

	function parseTypeAlias(start:SourceSpan, isPrivate:Bool):AstTypeAlias {
		var name = consume(TokenKind.Identifier).text;
		consume(TokenKind.Assign);
		var type = parseType(), end = previous().span;
		switch type {
			case AnonymousType(_):
				if (match(TokenKind.Semicolon))
					end = previous().span;
			default:
				end = consume(TokenKind.Semicolon).span;
		}
		return {
			name: name,
			type: type,
			isPrivate: isPrivate,
			span: start.merge(end)
		};
	}

	function parseEnum(start:SourceSpan):AstEnum {
		var name = consume(TokenKind.Identifier).text, cases = [];
		consume(TokenKind.LeftBrace);
		while (!check(TokenKind.RightBrace)) {
			var caseToken = consumeName(),
				params:Array<compiler.Ast.AstEnumParameter> = [];
			if (match(TokenKind.LeftParen)) {
				if (!check(TokenKind.RightParen))
					do {
						var optional = match(TokenKind.Question),
							parameterStart = current().span,
							name:Null<String> = null;
						if (check(TokenKind.Identifier) && peekKind(1) == TokenKind.Colon) {
							name = advance().text;
							advance();
						}
						var type = parseType();
						params.push({
							name: name,
							type: type,
							optional: optional,
							span: parameterStart.merge(previous().span)
						});
					} while (match(TokenKind.Comma));
				consume(TokenKind.RightParen);
			}
			cases.push({name: caseToken.text, params: params, span: caseToken.span.merge(previous().span)});
			consume(TokenKind.Semicolon);
		}
		var end = consume(TokenKind.RightBrace).span;
		return {name: name, cases: cases, span: start.merge(end)};
	}

	function parseQualifiedName():String {
		var name = consumeName().text;
		while (match(TokenKind.Dot))
			name += "." + consumeName().text;
		return name;
	}

	function parseFunction(allowMissingReturn:Bool):AstFunction {
		var start = consume(TokenKind.Function).span,
			name = check(TokenKind.New) ? advance().text : consume(TokenKind.Identifier).text;
		return parseFunctionBody(start, name, allowMissingReturn, false);
	}

	function parseFunctionBody(start:SourceSpan, name:String, allowMissingReturn:Bool, isStatic:Bool = false):AstFunction {
		var typeParameters = parseTypeParameters();
		consume(TokenKind.LeftParen);
		var arguments = [];
		if (!check(TokenKind.RightParen)) {
			do {
				var optional = match(TokenKind.Question),
					argumentToken = consume(TokenKind.Identifier);
				var argumentType = match(TokenKind.Colon) ? parseType() : InferredType,
					defaultValue = match(TokenKind.Assign) ? parseExpression() : null;
				arguments.push({
					name: argumentToken.text,
					type: argumentType,
					span: argumentToken.span.merge(previous().span),
					optional: optional || defaultValue != null,
					defaultValue: defaultValue
				});
			} while (match(TokenKind.Comma));
		}
		consume(TokenKind.RightParen);
		var result = match(TokenKind.Colon) ? parseType() : allowMissingReturn && name == "new" ? VoidType : InferredType;
		var statements = [], end:SourceSpan;
		if (match(TokenKind.LeftBrace)) {
			while (!check(TokenKind.RightBrace))
				appendStatements(statements, parseStatements());
			end = consume(TokenKind.RightBrace).span;
		} else {
			appendStatements(statements, parseStatements());
			end = statementSpan(statements[statements.length - 1]);
		}
		return {
			name: name,
			isStatic: isStatic,
			typeParameters: typeParameters,
			arguments: arguments,
			result: result,
			statements: statements,
			span: start.merge(end)
		};
	}

	function parseTypeParameters():Array<String> {
		var result = [];
		if (!match(TokenKind.Less))
			return result;
		do {
			var parameter = consume(TokenKind.Identifier);
			if (result.indexOf(parameter.text) >= 0)
				fail(parameter, 'Duplicate type parameter "${parameter.text}"');
			result.push(parameter.text);
		} while (match(TokenKind.Comma));
		consume(TokenKind.Greater);
		return result;
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
					case TokenKind.Inline:
						advance();
					case TokenKind.Final:
						advance();
						isFinal = true;
					default:
						break;
				}
				if (current().kind != TokenKind.Public && current().kind != TokenKind.Private && current().kind != TokenKind.Static
					&& current().kind != TokenKind.Inline && current().kind != TokenKind.Final)
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
				var readAccess = null, writeAccess = null;
				if (match(TokenKind.LeftParen)) {
					readAccess = parseFieldAccess();
					consume(TokenKind.Comma);
					writeAccess = parseFieldAccess();
					consume(TokenKind.RightParen);
				}
				var fieldType = match(TokenKind.Colon) ? parseType() : null,
					initializer = match(TokenKind.Assign) ? parseExpression() : null;
				if (fieldType == null) {
					if (initializer == null)
						fail(current(), 'Field "$fieldName" requires a type or initializer');
				}
				var end = consume(TokenKind.Semicolon).span;
				fields.push({
					name: fieldName,
					type: fieldType,
					initializer: initializer,
					readAccess: readAccess,
					writeAccess: writeAccess,
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

	function parseFieldAccess():AstFieldAccess {
		var token = advance();
		var access:Null<AstFieldAccess> = switch token.text {
			case "null": NullAccess;
			case "default": DefaultAccess;
			case "never": NeverAccess;
			case "get": GetAccess;
			case "set": SetAccess;
			case "dynamic": DynamicAccess;
			default: null;
		};
		if (access == null)
			fail(token, 'Unknown property access mode "${token.text}"');
		return access;
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
			var typeParameters = parseTypeParameters();
			consume(TokenKind.LeftParen);
			var arguments = [];
			if (!check(TokenKind.RightParen))
				do {
					var optional = match(TokenKind.Question),
						argumentName = consume(TokenKind.Identifier).text;
					consume(TokenKind.Colon);
					arguments.push({
						name: argumentName,
						type: parseType(),
						span: previous().span,
						optional: optional,
						defaultValue: null
					});
				} while (match(TokenKind.Comma));
			consume(TokenKind.RightParen);
			var result = match(TokenKind.Colon) ? parseType() : failType("Interface methods require a return type"),
				end = consume(TokenKind.Semicolon).span;
			methods.push({
				name: methodName,
				isStatic: false,
				typeParameters: typeParameters,
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
		if (match(TokenKind.Function)) {
			var start = previous().span,
				name = consume(TokenKind.Identifier).text;
			consume(TokenKind.LeftParen);
			var arguments = [];
			if (!check(TokenKind.RightParen))
				do {
					var optional = match(TokenKind.Question),
						argument = consume(TokenKind.Identifier),
						type = match(TokenKind.Colon) ? parseType() : InferredType,
						defaultValue = match(TokenKind.Assign) ? parseExpression() : null;
					arguments.push({
						name: argument.text,
						type: type,
						span: argument.span.merge(previous().span),
						optional: optional || defaultValue != null,
						defaultValue: defaultValue
					});
				} while (match(TokenKind.Comma));
			consume(TokenKind.RightParen);
			var result = match(TokenKind.Colon) ? parseType() : null,
				body = parseStatementOrBlock(),
				end = body.length == 0 ? previous().span : statementSpan(body[body.length - 1]),
				span = start.merge(end),
				declared = result == null ? null : FunctionType([for (argument in arguments) argument.type], result);
			return VarDeclaration(name, declared, Lambda(arguments, body, span), span);
		}
		if (match(TokenKind.Break)) {
			var start = previous().span;
			return Break(start.merge(consume(TokenKind.Semicolon).span));
		}
		if (match(TokenKind.Continue)) {
			var start = previous().span;
			return Continue(start.merge(consume(TokenKind.Semicolon).span));
		}
		if (match(TokenKind.Var)) {
			var start = previous().span;
			var name = consume(TokenKind.Identifier).text;
			var type = match(TokenKind.Colon) ? parseType() : null;
			consume(TokenKind.Assign);
			var initializer = parseExpression();
			var end = expressionEnd(initializer);
			return VarDeclaration(name, type, initializer, start.merge(end));
		}
		if (match(TokenKind.Return)) {
			var start = previous().span;
			if (check(TokenKind.Semicolon))
				return ReturnVoid(start.merge(consume(TokenKind.Semicolon).span));
			var expression = parseExpression();
			var end = expressionEnd(expression);
			return Return(expression, start.merge(end));
		}
		if (match(TokenKind.Throw)) {
			var start = previous().span,
				expression = parseExpression(),
				end = expressionEnd(expression);
			return Throw(expression, start.merge(end));
		}
		if (match(TokenKind.Try)) {
			var start = previous().span,
				tryBranch = parseTryBody(),
				catches:Array<compiler.Ast.AstCatch> = [],
				end = previous().span;
			do {
				var catchStart = consume(TokenKind.Catch).span;
				consume(TokenKind.LeftParen);
				var catchName = consume(TokenKind.Identifier).text;
				consume(TokenKind.Colon);
				var catchType = parseType();
				consume(TokenKind.RightParen);
				var catchBranch = parseStatementOrBlock();
				end = catchBranch.length == 0 ? previous().span : statementSpan(catchBranch[catchBranch.length - 1]);
				catches.push({
					name: catchName,
					type: catchType,
					statements: catchBranch,
					span: catchStart.merge(end)
				});
			} while (check(TokenKind.Catch));
			return Try(tryBranch, catches, start.merge(end));
		}
		if (match(TokenKind.Switch)) {
			var start = previous().span;
			var expression:AstExpression;
			if (match(TokenKind.LeftParen)) {
				expression = parseExpression();
				consume(TokenKind.RightParen);
			} else
				expression = parseExpression();
			consume(TokenKind.LeftBrace);
			var cases = [];
			while (match(TokenKind.Case)) {
				var caseStart = previous().span, values = [parseExpression()];
				while (match(TokenKind.Comma))
					values.push(parseExpression());
				consume(TokenKind.Colon);
				var statements = [];
				while (!check(TokenKind.RightBrace) && !check(TokenKind.Case) && !check(TokenKind.Default))
					appendStatements(statements, parseStatements());
				var caseEnd = statements.length == 0 ? expressionSpan(values[values.length - 1]) : statementSpan(statements[statements.length - 1]);
				for (value in values)
					cases.push({value: value, statements: statements, span: caseStart.merge(caseEnd)});
			}
			var defaultBranch = [], hasDefault = match(TokenKind.Default);
			if (hasDefault) {
				consume(TokenKind.Colon);
				while (!check(TokenKind.RightBrace))
					appendStatements(defaultBranch, parseStatements());
			}
			var end = consume(TokenKind.RightBrace).span;
			if (match(TokenKind.Semicolon))
				end = previous().span;
			return Switch(expression, cases, defaultBranch, hasDefault, start.merge(end));
		}
		if (check(TokenKind.Identifier) || check(TokenKind.This)) {
			var saved = position, target = parseExpression();
			if (match(TokenKind.Increment) || match(TokenKind.Decrement)) {
				var delta = previous().kind == TokenKind.Increment ? 1 : -1,
					end = consume(TokenKind.Semicolon).span;
				return switch target {
					case Variable(name, _):
						Increment(name, delta, expressionSpan(target).merge(end));
					default: throw new CompileError(new Diagnostic("E0002", "Increment target must be a variable", expressionSpan(target)));
				};
			}
			var assignmentKind = match(TokenKind.Assign) ? 0 : match(TokenKind.PlusAssign) ? 1 : match(TokenKind.MinusAssign) ? 2 : -1;
			if (assignmentKind >= 0) {
				var value = parseExpression(),
					end = expressionEnd(value),
					assigned = assignmentKind == 0 ? value : assignmentKind == 1 ? Add(target, value,
						expressionSpan(target).merge(expressionSpan(value))) : Sub(target, value, expressionSpan(target).merge(expressionSpan(value))),
					assignment = switch target {
						case Variable(name, _): Assignment(name, assigned, expressionSpan(target).merge(end));
						case Index(array, offset, _): IndexAssignment(array, offset, assigned, expressionSpan(target).merge(end));
						case Member(object, field, _): FieldAssignment(object, field, assigned, expressionSpan(target).merge(end));
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
		if (match(TokenKind.Do)) {
			var start = previous().span, body = parseDoWhileBody();
			consume(TokenKind.While);
			consume(TokenKind.LeftParen);
			var condition = parseExpression();
			consume(TokenKind.RightParen);
			var end = consume(TokenKind.Semicolon).span;
			return DoWhile(body, condition, start.merge(end));
		}
		if (match(TokenKind.For)) {
			var start = previous().span;
			consume(TokenKind.LeftParen);
			match(TokenKind.Var);
			var name = consume(TokenKind.Identifier).text, valueName = null;
			if (match(TokenKind.Assign)) {
				consume(TokenKind.Greater);
				valueName = consume(TokenKind.Identifier).text;
			}
			consume(TokenKind.In);
			var iterable = parseExpression();
			consume(TokenKind.RightParen);
			var body = parseStatementOrBlock(),
				end = statementSpan(body[body.length - 1]);
			return ForIn(name, valueName, iterable, body, start.merge(end));
		}
		var expression = parseExpression(), end = expressionEnd(expression);
		return Expression(expression, expressionSpan(expression).merge(end));
	}

	function parseTryBody():Array<AstStatement> {
		if (check(TokenKind.LeftBrace))
			return parseStatementOrBlock();
		var expression = parseExpression();
		match(TokenKind.Semicolon);
		return [Expression(expression, expressionSpan(expression))];
	}

	function parseDoWhileBody():Array<AstStatement> {
		if (check(TokenKind.LeftBrace))
			return parseStatementOrBlock();
		var expression = parseExpression();
		match(TokenKind.Semicolon);
		return [Expression(expression, expressionSpan(expression))];
	}

	function parseAnonymousFunctionBody():Array<AstStatement> {
		if (!check(TokenKind.LeftBrace) && match(TokenKind.Return)) {
			var start = previous().span, value = parseExpression();
			match(TokenKind.Semicolon);
			return [Return(value, start.merge(expressionSpan(value)))];
		}
		return parseStatementOrBlock();
	}

	function parseStatements():Array<AstStatement> {
		if (!check(TokenKind.Var))
			return [parseStatement()];
		var start = advance().span, declarations = [];
		do {
			var nameToken = consume(TokenKind.Identifier),
				type = match(TokenKind.Colon) ? parseType() : null;
			if (match(TokenKind.Assign)) {
				var initializer = parseExpression();
				declarations.push(VarDeclaration(nameToken.text, type, initializer, start.merge(expressionSpan(initializer))));
			} else {
				if (type == null)
					fail(current(), 'Uninitialized local "${nameToken.text}" requires an explicit type');
				declarations.push(UninitializedDeclaration(nameToken.text, type, start.merge(previous().span)));
			}
		} while (match(TokenKind.Comma));
		var lastInitializer = switch declarations[declarations.length - 1] {
			case VarDeclaration(_, _, initializer, _): initializer;
			default: null;
		};
		var end = lastInitializer != null ? expressionEnd(lastInitializer) : consume(TokenKind.Semicolon).span;
		if (declarations.length > 0) {
			var last = declarations.length - 1;
			switch declarations[last] {
				case VarDeclaration(name, type, initializer, _):
					declarations[last] = VarDeclaration(name, type, initializer, start.merge(end));
				case UninitializedDeclaration(name, type, _):
					declarations[last] = UninitializedDeclaration(name, type, start.merge(end));
				default:
			}
		}
		return declarations;
	}

	static function appendStatements(target:Array<AstStatement>, statements:Array<AstStatement>):Void
		for (statement in statements)
			target.push(statement);

	function parseExpression():AstExpression {
		var expression = parseOr();
		if (check(TokenKind.Dot) && peekKind(1) == TokenKind.Dot && peekKind(2) == TokenKind.Dot) {
			advance();
			advance();
			advance();
			var end = parseOr();
			expression = Range(expression, end, expressionSpan(expression).merge(expressionSpan(end)));
		}
		if (match(TokenKind.Question)) {
			var whenTrue = parseExpression();
			consume(TokenKind.Colon);
			var whenFalse = parseExpression();
			expression = Conditional(expression, whenTrue, whenFalse, expressionSpan(expression).merge(expressionSpan(whenFalse)));
		}
		return expression;
	}

	function parseOr():AstExpression {
		var expression = parseAnd();
		while (match(TokenKind.OrOr)) {
			var right = parseAnd(),
				span = expressionSpan(expression).merge(expressionSpan(right));
			expression = Or(expression, right, span);
		}
		return expression;
	}

	function parseAnd():AstExpression {
		var expression = parseBitOr();
		while (match(TokenKind.AndAnd)) {
			var right = parseBitOr(),
				span = expressionSpan(expression).merge(expressionSpan(right));
			expression = And(expression, right, span);
		}
		return expression;
	}

	function parseBitOr():AstExpression {
		var expression = parseBitXor();
		while (match(TokenKind.Pipe)) {
			var right = parseBitXor();
			expression = BitOr(expression, right, expressionSpan(expression).merge(expressionSpan(right)));
		}
		return expression;
	}

	function parseBitXor():AstExpression {
		var expression = parseBitAnd();
		while (match(TokenKind.Caret)) {
			var right = parseBitAnd();
			expression = BitXor(expression, right, expressionSpan(expression).merge(expressionSpan(right)));
		}
		return expression;
	}

	function parseBitAnd():AstExpression {
		var expression = parseComparison();
		while (match(TokenKind.Ampersand)) {
			var right = parseComparison();
			expression = BitAnd(expression, right, expressionSpan(expression).merge(expressionSpan(right)));
		}
		return expression;
	}

	function parseComparison():AstExpression {
		var expression = parseShift();
		if (check(TokenKind.Less) || check(TokenKind.LessEqual) || check(TokenKind.Greater) || check(TokenKind.GreaterEqual) || check(TokenKind.EqualEqual)
			|| check(TokenKind.NotEqual)) {
			var operation = advance().kind;
			var right = parseShift();
			var span = expressionSpan(expression).merge(expressionSpan(right));
			expression = switch operation {
				case TokenKind.Less: Less(expression, right, span);
				case TokenKind.LessEqual: LessEqual(expression, right, span);
				case TokenKind.Greater: Greater(expression, right, span);
				case TokenKind.GreaterEqual: GreaterEqual(expression, right, span);
				case TokenKind.NotEqual: NotEqual(expression, right, span);
				default: Equal(expression, right, span);
			}
		}
		return expression;
	}

	function parseShift():AstExpression {
		var expression = parseAdditive();
		while (isAdjacentPair(TokenKind.Less) || isAdjacentPair(TokenKind.Greater)) {
			var leftShift = check(TokenKind.Less),
				unsigned = !leftShift && isAdjacentTriple(TokenKind.Greater);
			advance();
			advance();
			if (unsigned)
				advance();
			var right = parseAdditive(),
				span = expressionSpan(expression).merge(expressionSpan(right));
			expression = leftShift ? ShiftLeft(expression, right,
				span) : unsigned ? UnsignedShiftRight(expression, right, span) : ShiftRight(expression, right, span);
		}
		return expression;
	}

	function isAdjacentPair(kind:TokenKind):Bool
		return check(kind) && peekKind(1) == kind && current().span.end == tokens[position + 1].span.start;

	function isAdjacentTriple(kind:TokenKind):Bool
		return isAdjacentPair(kind) && peekKind(2) == kind && tokens[position + 1].span.end == tokens[position + 2].span.start;

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
		while (check(TokenKind.Star) || check(TokenKind.Slash) || check(TokenKind.Percent)) {
			var operation = advance().kind,
				right = parsePrimary(),
				span = expressionSpan(expression).merge(expressionSpan(right));
			expression = switch operation {
				case TokenKind.Star: Mul(expression, right, span);
				case TokenKind.Slash: Div(expression, right, span);
				default: Mod(expression, right, span);
			};
		}
		return expression;
	}

	function parsePrimary():AstExpression {
		if (match(TokenKind.Switch))
			return parseSwitchExpression(previous().span);
		if (match(TokenKind.Throw)) {
			var start = previous().span, value = parseExpression();
			return ThrowExpression(value, start.merge(expressionSpan(value)));
		}
		if (check(TokenKind.Identifier) && current().text == "cast") {
			var start = advance().span;
			if (match(TokenKind.LeftParen)) {
				var value = parseExpression(), target = null;
				if (match(TokenKind.Comma))
					target = parseType();
				var end = consume(TokenKind.RightParen).span;
				return parsePostfix(Cast(value, target, start.merge(end)));
			}
			var value = parsePrimary();
			return Cast(value, null, start.merge(expressionSpan(value)));
		}
		if (match(TokenKind.Function)) {
			var start = previous().span;
			consume(TokenKind.LeftParen);
			var arguments = [];
			if (!check(TokenKind.RightParen))
				do {
					var optional = match(TokenKind.Question),
						argument = consume(TokenKind.Identifier),
						type = match(TokenKind.Colon) ? parseType() : InferredType,
						defaultValue = match(TokenKind.Assign) ? parseExpression() : null;
					arguments.push({
						name: argument.text,
						type: type,
						span: argument.span.merge(previous().span),
						optional: optional || defaultValue != null,
						defaultValue: defaultValue
					});
				} while (match(TokenKind.Comma));
			consume(TokenKind.RightParen);
			var body = parseAnonymousFunctionBody(),
				end = body.length == 0 ? previous().span : statementSpan(body[body.length - 1]);
			return Lambda(arguments, body, start.merge(end));
		}
		if (match(TokenKind.If)) {
			var start = previous().span;
			consume(TokenKind.LeftParen);
			var condition = parseExpression();
			consume(TokenKind.RightParen);
			var whenTrue = parseExpressionBranch();
			match(TokenKind.Semicolon);
			consume(TokenKind.Else);
			var whenFalse = parseExpressionBranch();
			return Conditional(condition, whenTrue, whenFalse, start.merge(expressionSpan(whenFalse)));
		}
		if (match(TokenKind.Minus)) {
			var start = previous().span, value = parsePrimary();
			return Negate(value, start.merge(expressionSpan(value)));
		}
		if (match(TokenKind.Not)) {
			var start = previous().span, value = parsePrimary();
			return Not(value, start.merge(expressionSpan(value)));
		}
		if (match(TokenKind.Integer))
			return parsePostfix(IntegerLiteral(Std.parseInt(previous().text), previous().span));
		if (match(TokenKind.Float))
			return parsePostfix(FloatLiteral(Std.parseFloat(previous().text), previous().span));
		if (match(TokenKind.StringLiteral))
			return parsePostfix(StringLiteral(decodeString(previous().text), previous().span));
		if (match(TokenKind.BoolTrue))
			return parsePostfix(BoolLiteral(true, previous().span));
		if (match(TokenKind.BoolFalse))
			return parsePostfix(BoolLiteral(false, previous().span));
		if (match(TokenKind.LeftBracket)) {
			var start = previous().span, values = [];
			if (match(TokenKind.For)) {
				consume(TokenKind.LeftParen);
				var keyName = consume(TokenKind.Identifier).text,
					valueName = null;
				if (match(TokenKind.Assign)) {
					consume(TokenKind.Greater);
					valueName = consume(TokenKind.Identifier).text;
				}
				consume(TokenKind.In);
				var iterable = parseExpression();
				consume(TokenKind.RightParen);
				var condition = null;
				if (match(TokenKind.If)) {
					consume(TokenKind.LeftParen);
					condition = parseExpression();
					consume(TokenKind.RightParen);
				}
				var value = parseComprehensionValue(),
					end = consume(TokenKind.RightBracket).span;
				return parsePostfix(ArrayComprehension(keyName, valueName, iterable, condition, value, start.merge(end)));
			}
			if (!check(TokenKind.RightBracket)) {
				var first = parseExpression();
				if (match(TokenKind.Assign)) {
					consume(TokenKind.Greater);
					var entries = [], value = parseExpression();
					entries.push({key: first, value: value, span: expressionSpan(first).merge(expressionSpan(value))});
					while (match(TokenKind.Comma)) {
						if (check(TokenKind.RightBracket))
							break;
						var key = parseExpression();
						consume(TokenKind.Assign);
						consume(TokenKind.Greater);
						var entryValue = parseExpression();
						entries.push({key: key, value: entryValue, span: expressionSpan(key).merge(expressionSpan(entryValue))});
					}
					var end = consume(TokenKind.RightBracket).span;
					return parsePostfix(MapLiteral(entries, start.merge(end)));
				}
				values.push(first);
				while (match(TokenKind.Comma))
					if (!check(TokenKind.RightBracket))
						values.push(parseExpression());
			}
			var end = consume(TokenKind.RightBracket).span;
			return parsePostfix(ArrayLiteral(values, start.merge(end)));
		}
		if (check(TokenKind.Identifier) && current().text == "null") {
			var nullToken = advance();
			return parsePostfix(NullLiteral(nullToken.span));
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
			if (check(TokenKind.Identifier) && current().text == "Map") {
				advance();
				consume(TokenKind.Less);
				var key = parseType();
				consume(TokenKind.Comma);
				var value = parseType();
				consume(TokenKind.Greater);
				consume(TokenKind.LeftParen);
				var end = consume(TokenKind.RightParen).span;
				return parsePostfix(NewMap(key, value, start.merge(end)));
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
							&& tokens[lambdaStart + 1].kind == TokenKind.Colon)
						|| (tokens[lambdaStart].kind == TokenKind.Question
							&& lambdaStart + 2 < tokens.length
							&& tokens[lambdaStart + 2].kind == TokenKind.Colon));
			if (!isLambda) {
				advance();
				var grouped = parseExpression();
				if (match(TokenKind.Colon)) {
					var target = parseType(),
						end = consume(TokenKind.RightParen).span;
					grouped = Cast(grouped, target, start.merge(end));
				} else
					consume(TokenKind.RightParen);
				return parsePostfix(grouped);
			}
			advance();
			var arguments = [];
			if (!check(TokenKind.RightParen)) {
				do {
					var optional = match(TokenKind.Question),
						argumentStart = current().span,
						argumentName = consume(TokenKind.Identifier).text;
					consume(TokenKind.Colon);
					arguments.push({
						name: argumentName,
						type: parseType(),
						span: argumentStart.merge(previous().span),
						optional: optional,
						defaultValue: null
					});
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
			while (check(TokenKind.Dot) && peekKind(1) != TokenKind.Dot) {
				advance();
				name += "." + consumeName().text;
			}
			var expression:AstExpression = Variable(name, start);
			return parsePostfix(expression);
		}
		if (match(TokenKind.LeftBrace)) {
			var start = previous().span, fields = [];
			if (!check(TokenKind.RightBrace)) {
				while (true) {
					var name = consume(TokenKind.Identifier);
					consume(TokenKind.Colon);
					var value = parseExpression();
					fields.push({name: name.text, value: value, span: name.span.merge(expressionSpan(value))});
					if (!match(TokenKind.Comma) || check(TokenKind.RightBrace))
						break;
				}
			}
			var end = consume(TokenKind.RightBrace).span;
			return parsePostfix(ObjectLiteral(fields, start.merge(end)));
		}
		if (isNameToken(current().kind)) {
			var nameToken = consumeName(),
				name = nameToken.text,
				start = nameToken.span;
			while (check(TokenKind.Dot) && peekKind(1) != TokenKind.Dot) {
				advance();
				name += "." + consumeName().text;
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

	function parseComprehensionValue():AstExpression {
		if (check(TokenKind.LeftBrace) && !(peekKind(1) == TokenKind.Identifier && peekKind(2) == TokenKind.Colon))
			return parseExpressionBranch();
		return parseExpression();
	}

	function parseExpressionBranch():AstExpression {
		if (!match(TokenKind.LeftBrace))
			return parseExpression();
		var start = previous().span, statements = [];
		while (!check(TokenKind.RightBrace)) {
			if (isStatementOnlyStart(current().kind)) {
				appendStatements(statements, parseStatements());
				continue;
			}
			var saved = position, candidate = tryParseExpression();
			if (candidate != null && check(TokenKind.RightBrace)) {
				var end = consume(TokenKind.RightBrace).span;
				return BlockExpression(statements, candidate, start.merge(end));
			}
			position = saved;
			appendStatements(statements, parseStatements());
		}
		if (statements.length > 0)
			switch statements[statements.length - 1] {
				case Expression(result, _):
					statements.pop();
					var end = consume(TokenKind.RightBrace).span;
					return BlockExpression(statements, result, start.merge(end));
				default:
			}
		fail(current(), "Expression block requires a result expression");
		return null;
	}

	function parseSwitchExpression(start:SourceSpan):AstExpression {
		var subject:AstExpression;
		if (match(TokenKind.LeftParen)) {
			subject = parseExpression();
			consume(TokenKind.RightParen);
		} else
			subject = parseExpression();
		consume(TokenKind.LeftBrace);
		var cases = [];
		while (match(TokenKind.Case)) {
			var caseStart = previous().span, values = [parseExpression()];
			while (match(TokenKind.Comma))
				values.push(parseExpression());
			consume(TokenKind.Colon);
			var result = parseSwitchExpressionBranch();
			for (value in values)
				cases.push({value: value, result: result, span: caseStart.merge(expressionSpan(result))});
		}
		var fallback = null;
		if (match(TokenKind.Default)) {
			consume(TokenKind.Colon);
			fallback = parseSwitchExpressionBranch();
		}
		var end = consume(TokenKind.RightBrace).span;
		return parsePostfix(SwitchExpression(subject, cases, fallback, start.merge(end)));
	}

	function parseSwitchExpressionBranch():AstExpression {
		var statements = [], start = current().span;
		while (true) {
			if (isStatementOnlyStart(current().kind)) {
				appendStatements(statements, parseStatements());
				continue;
			}
			var saved = position, result = tryParseExpression();
			if (result != null && match(TokenKind.Semicolon)) {
				if (atSwitchBranchEnd())
					return statements.length == 0 ? result : BlockExpression(statements, result, start.merge(expressionSpan(result)));
				position = saved;
				appendStatements(statements, parseStatements());
				continue;
			}
			if (result != null && atSwitchBranchEnd())
				return statements.length == 0 ? result : BlockExpression(statements, result, start.merge(expressionSpan(result)));
			position = saved;
			appendStatements(statements, parseStatements());
		}
	}

	function atSwitchBranchEnd():Bool
		return check(TokenKind.Case) || check(TokenKind.Default) || check(TokenKind.RightBrace);

	static function isStatementOnlyStart(kind:TokenKind):Bool
		return switch kind {
			case TokenKind.Var, TokenKind.Return, TokenKind.Try, TokenKind.While, TokenKind.Do, TokenKind.For, TokenKind.Break, TokenKind.Continue: true;
			default: false;
		};

	function tryParseExpression():Null<AstExpression> {
		var saved = position;
		try {
			return parseExpression();
		} catch (_:CompileError) {
			position = saved;
			return null;
		}
	}

	function parsePostfix(expression:AstExpression):AstExpression {
		while (true) {
			if (check(TokenKind.Dot) && peekKind(1) == TokenKind.Dot && peekKind(2) == TokenKind.Dot)
				break;
			if (match(TokenKind.LeftParen)) {
				var arguments = [];
				if (!check(TokenKind.RightParen)) {
					do
						arguments.push(parseExpression()) while (match(TokenKind.Comma));
				}
				var end = consume(TokenKind.RightParen).span;
				expression = switch expression {
					case Variable(name, start): Call(name, arguments, expressionSpan(expression).merge(end));
					default:
						throw new CompileError(new Diagnostic("E0002", "Call target must be a function or method", expressionSpan(expression)));
				};
				continue;
			}
			if (match(TokenKind.LeftBracket)) {
				var offset = parseExpression(),
					end = consume(TokenKind.RightBracket).span;
				expression = Index(expression, offset, expressionSpan(expression).merge(end));
				continue;
			}
			if (match(TokenKind.Dot)) {
				var nameToken = consumeName(), name = nameToken.text;
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
			if (match(TokenKind.Increment) || match(TokenKind.Decrement)) {
				var end = previous().span,
					delta = previous().kind == TokenKind.Increment ? 1 : -1;
				expression = PostfixIncrement(expression, delta, expressionSpan(expression).merge(end));
				break;
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
		if (match(TokenKind.LeftBrace)) {
			var fields = [];
			while (!check(TokenKind.RightBrace)) {
				var optional = false;
				while (check(TokenKind.Question) || check(TokenKind.Final) || check(TokenKind.Var))
					if (match(TokenKind.Question)) {
						if (optional)
							fail(previous(), "Duplicate optional field marker");
						optional = true;
					} else
						advance();
				var name = consume(TokenKind.Identifier);
				consume(TokenKind.Colon);
				var type = parseType();
				fields.push({
					name: name.text,
					type: type,
					optional: optional,
					span: name.span.merge(previous().span)
				});
				if (!match(TokenKind.Comma))
					match(TokenKind.Semicolon);
			}
			consume(TokenKind.RightBrace);
			return AnonymousType(fields);
		}
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
			} else if (current().text == "Map") {
				advance();
				consume(TokenKind.Less);
				var key = parseType();
				consume(TokenKind.Comma);
				var value = parseType();
				consume(TokenKind.Greater);
				return MapType(key, value);
			} else if (current().text == "Null") {
				advance();
				consume(TokenKind.Less);
				var element = parseType();
				consume(TokenKind.Greater);
				return NullableType(element);
			}
		var name = parseQualifiedName();
		if (name == "hl.Abstract" && match(TokenKind.Less)) {
			var tag = consume(TokenKind.StringLiteral),
				value = decodeString(tag.text);
			consume(TokenKind.Greater);
			return NativeAbstractType(value);
		}
		return NamedType(name);
		fail(current(), 'Expected type, got ${current().kind}');
		return null;
	}

	function failType(message:String):AstType {
		fail(current(), message);
		return null;
	}

	function parseStatementOrBlock():Array<AstStatement> {
		if (!match(TokenKind.LeftBrace))
			return parseStatements();
		var statements = [];
		while (!check(TokenKind.RightBrace))
			appendStatements(statements, parseStatements());
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

	function consumeName():Token {
		return if (isNameToken(current().kind)) advance(); else {
			fail(current(), 'Expected name, got ${current().kind}');
			null;
		};
	}

	function expressionEnd(expression:AstExpression):SourceSpan {
		if (match(TokenKind.Semicolon))
			return previous().span;
		if (isBracedExpression(expression))
			return expressionSpan(expression);
		return consume(TokenKind.Semicolon).span;
	}

	static function isBracedExpression(expression:AstExpression):Bool
		return switch expression {
			case SwitchExpression(_, _, _, _), BlockExpression(_, _, _): true;
			case Conditional(_, whenTrue, whenFalse, _): isBracedExpression(whenTrue) || isBracedExpression(whenFalse);
			default: false;
		};

	static function isNameToken(kind:TokenKind):Bool {
		return switch kind {
			case TokenKind.Identifier, TokenKind.TypeInt, TokenKind.TypeBool, TokenKind.TypeFloat, TokenKind.TypeString, TokenKind.Void: true;
			default:
				false;
		};
	}

	function check(kind:TokenKind):Bool
		return current().kind == kind;

	function advance():Token
		return tokens[position++];

	function current():Token
		return tokens[position];

	function peekKind(offset:Int):TokenKind
		return position + offset < tokens.length ? tokens[position + offset].kind : TokenKind.Eof;

	function previous():Token
		return tokens[position - 1];

	function fail(token:Token, message:String):Void
		throw new CompileError(new Diagnostic("E0002", message, token.span));

	static function expressionSpan(expression:AstExpression)
		return switch expression {
			case IntegerLiteral(_, span), FloatLiteral(_, span), StringLiteral(_, span), BoolLiteral(_, span), NullLiteral(span), Variable(_, span),
				Member(_, _, span), Add(_, _, span), Sub(_, _, span), Mul(_, _, span), Div(_, _, span), Mod(_, _, span), BitAnd(_, _, span),
				BitXor(_, _, span), BitOr(_, _, span), ShiftLeft(_, _, span), ShiftRight(_, _, span), UnsignedShiftRight(_, _, span), Negate(_, span),
				Less(_, _, span), LessEqual(_, _, span), Greater(_, _, span), GreaterEqual(_, _, span), Equal(_, _, span), NotEqual(_, _, span), Not(_, span),
				Call(_, _, span), MethodCall(_, _, _, span), New(_, _, span), NewArray(_, _, span), NewMap(_, _, span), Index(_, _, span),
				PostfixIncrement(_, _, span), Lambda(_, _, span), And(_, _, span), Or(_, _, span), Conditional(_, _, _, span), BlockExpression(_, _, span),
				ThrowExpression(_, span), SwitchExpression(_, _, _, span), Cast(_, _, span): span;
			case ObjectLiteral(_, span), ArrayLiteral(_, span), MapLiteral(_, span), ArrayComprehension(_, _, _, _, _, span), Range(_, _, span): span;
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
			case UninitializedDeclaration(_, _, span), VarDeclaration(_, _, _, span), Assignment(_, _, span), IndexAssignment(_, _, _, span),
				FieldAssignment(_, _, _, span), Return(_, span), ReturnVoid(span), Throw(_, span), Try(_, _, span), If(_, _, _, span), While(_, _, span),
				DoWhile(_, _,
					span), ForIn(_, _, _, _, span), Break(span), Continue(span), Switch(_, _, _, _, span), Increment(_, _, span), Expression(_, span): span;
		}
}
