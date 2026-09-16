package compiler.syntax;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstFieldAccess;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstInterface;
import compiler.syntax.Ast.AstTypeAlias;
import compiler.syntax.Ast.AstEnum;
import compiler.syntax.Ast.AstEnumAbstract;
import compiler.syntax.Ast.AstAbstract;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.NativeLayoutQueryKind;
import compiler.Source.SourceSpan;
import compiler.syntax.Token.TokenKind;
import compiler.Diagnostic.CompileError;
import haxe.Int64;
import compiler.Diagnostic.DiagnosticOrigin;

typedef RecoveredParse = {
	final program:AstProgram;
	final diagnostics:Array<compiler.Diagnostic>;
}

/** Recursive-descent parser for the supported Haxe-compatible source subset. */
class Parser {
	static inline final MAX_RECOVERY_DIAGNOSTICS = 20;

	final tokens:Array<Token>;
	final checkpointCallback:Null<Void->Void>;
	var position:Int = 0;
	var recovering:Bool = false;
	var recoveryDiagnostics:Array<compiler.Diagnostic> = [];

	public function new(tokens:Array<Token>, ?checkpoint:Void->Void) {
		this.tokens = tokens;
		this.checkpointCallback = checkpoint;
	}

	public function parseProgram():AstProgram {
		var packageName:Null<String> = null, imports = [], importAliases:Map<String, String> = [];
		if (match(TokenKind.Package)) {
			packageName = parseQualifiedName();
			consume(TokenKind.Semicolon);
		}
		while (match(TokenKind.Import)) {
			var path = parseQualifiedName(true);
			if (recovering && check(TokenKind.Dot)) {
				advance();
				recordExpected("import name");
			}
			imports.push(path);
			if (check(TokenKind.Identifier) && current().text == "as") {
				advance();
				var alias = consumeDeclarationToken("import alias");
				if (alias.text != "<missing>") {
					if (importAliases.exists(alias.text))
						fail(alias, 'Duplicate import alias "${alias.text}"');
					importAliases.set(alias.text, path);
				}
			}
			consume(TokenKind.Semicolon);
		}
		var functions = [], aliases:Array<AstTypeAlias> = [], enums:Array<AstEnum> = [], enumAbstracts:Array<AstEnumAbstract> = [],
			abstracts:Array<AstAbstract> = [], interfaces:Array<AstInterface> = [], classes = [];
		while (!check(TokenKind.Eof)) {
			var declarationStart = position;
			try {
				var metadata = parseMetadata();
				if (isMacroModifier()) {
					skipMacroFunction();
					continue;
				}
				var visibility = match(TokenKind.Private) ? previous() : match(TokenKind.Public) ? previous() : null;
				var externDeclaration = check(TokenKind.Identifier) && current().text == "extern";
				if (externDeclaration)
					advance();
				if (match(TokenKind.Typedef))
					aliases.push(parseTypeAlias(visibility == null ? previous()
						.span : visibility.span, visibility != null && visibility.kind == TokenKind.Private));
				else if (match(TokenKind.Enum)) {
					var start = previous().span;
					if (check(TokenKind.Identifier) && current().text == "abstract") {
						advance();
						enumAbstracts.push(parseEnumAbstract(start));
					} else
						enums.push(parseEnum(start, metadata));
				} else if (check(TokenKind.Interface))
					interfaces.push(parseInterface());
				else if (check(TokenKind.Class))
					classes.push(parseClass(visibility != null && visibility.kind == TokenKind.Private, metadata, externDeclaration));
				else if (visibility != null)
					fail(current(), "Top-level visibility modifier is not supported for this declaration");
				else if (check(TokenKind.Identifier) && current().text == "abstract") {
					var start = advance().span;
					abstracts.push(parseAbstract(start, externDeclaration, metadata));
				} else
					functions.push(parseFunction(false, externDeclaration, metadata));
			} catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				synchronizeTopLevel(declarationStart);
			}
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

	/** Parse as much current source as possible for editor features. */
	public function parseProgramRecovering():RecoveredParse {
		recovering = true;
		recoveryDiagnostics = [];
		var program = parseProgram();
		return {program: program, diagnostics: recoveryDiagnostics.copy()};
	}

	function synchronizeTopLevel(declarationStart:Int):Void {
		var braceDepth = 0;
		for (index in 0...position)
			switch tokens[index].kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				default:
			}
		if (position <= declarationStart && !check(TokenKind.Eof))
			advance();
		while (!check(TokenKind.Eof)) {
			if (braceDepth == 0 && isTopLevelStart(current()))
				return;
			switch advance().kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				default:
			}
		}
	}

	static function isTopLevelStart(token:Token):Bool
		return switch token.kind {
			case TokenKind.Function, TokenKind.Class, TokenKind.Interface, TokenKind.Enum, TokenKind.Typedef, TokenKind.Public, TokenKind.Private,
				TokenKind.At: true;
			case TokenKind.Identifier: token.text == "abstract" || token.text == "extern";
			default: false;
		};

	function parseMetadata():Array<compiler.syntax.Ast.AstMetadata> {
		var result = [];
		while (match(TokenKind.At)) {
			var start = previous().span;
			consume(TokenKind.Colon);
			var name = parseQualifiedName(), arguments = [];
			if (match(TokenKind.LeftParen)) {
				if (!check(TokenKind.RightParen))
					do
						arguments.push(parseDelimitedExpression(TokenKind.RightParen, false)) while (match(TokenKind.Comma));
				var end = consume(TokenKind.RightParen).span;
				result.push({name: name, arguments: arguments, span: start.merge(end)});
			} else
				result.push({name: name, arguments: arguments, span: start.merge(previous().span)});
		}
		return result;
	}

	function parseAbstract(start:SourceSpan, isExtern:Bool = false, ?metadata:Array<compiler.syntax.Ast.AstMetadata>):AstAbstract {
		var name = consumeDeclarationName("abstract"),
			typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeParameters = parseTypeParameters(typeConstraints);
		if (recovering && (recoveringAtEnd() || isDeclarationBoundary(current()))) {
			var underlying = missingType("abstract underlying type");
			recordExpected("abstract body");
			return {
				name: name,
				isExtern: isExtern,
				metadata: metadata == null ? [] : metadata,
				typeParameters: typeParameters,
				typeConstraints: typeConstraints,
				underlying: underlying,
				fromTypes: [],
				toTypes: [],
				methods: [],
				span: start.merge(previous().span)
			};
		}
		consume(TokenKind.LeftParen);
		var underlying = parseType();
		consume(TokenKind.RightParen);
		var fromTypes = [], toTypes = [];
		while (!check(TokenKind.LeftBrace) && !recoveringAtEnd()) {
			var conversion = consume(TokenKind.Identifier);
			if (conversion.text != "from" && conversion.text != "to")
				fail(conversion, 'Expected "from" or "to"');
			var conversionType = parseType();
			if (conversion.text == "from")
				fromTypes.push(conversionType);
			else
				toTypes.push(conversionType);
		}
		if (recovering && isDeclarationBoundary(current())) {
			recordExpected("abstract body");
			return {
				name: name,
				isExtern: isExtern,
				metadata: metadata == null ? [] : metadata,
				typeParameters: typeParameters,
				typeConstraints: typeConstraints,
				underlying: underlying,
				fromTypes: fromTypes,
				toTypes: toTypes,
				methods: [],
				span: start.merge(previous().span)
			};
		}
		consume(TokenKind.LeftBrace);
		var methods = [], bodyStart = position;
		while (!check(TokenKind.RightBrace) && !recoveringAtEnd()) {
			var memberStart = position;
			try {
				var methodMetadata = parseMetadata();
				var isStatic = false;
				while (check(TokenKind.Public) || check(TokenKind.Private) || check(TokenKind.Inline) || check(TokenKind.Static)) {
					if (match(TokenKind.Static))
						isStatic = true;
					else
						advance();
				}
				var functionStart = consume(TokenKind.Function).span,
					methodName = check(TokenKind.New) ? advance().text : consumeDeclarationName("method");
				methods.push(parseFunctionBody(functionStart, methodName, true, isStatic, isExtern, methodMetadata));
			} catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				synchronizeAbstractMember(bodyStart, memberStart);
			}
		}
		var end = consume(TokenKind.RightBrace).span;
		return {
			name: name,
			isExtern: isExtern,
			metadata: metadata == null ? [] : metadata,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			underlying: underlying,
			fromTypes: fromTypes,
			toTypes: toTypes,
			methods: methods,
			span: start.merge(end)
		};
	}

	function parseEnumAbstract(start:SourceSpan):AstEnumAbstract {
		var name = consumeDeclarationName("enum abstract");
		if (recovering && (recoveringAtEnd() || isDeclarationBoundary(current()))) {
			var underlying = missingType("enum abstract underlying type");
			recordExpected("enum abstract body");
			return {
				name: name,
				underlying: underlying,
				fromTypes: [],
				toTypes: [],
				values: [],
				span: start.merge(previous().span)
			};
		}
		consume(TokenKind.LeftParen);
		var underlying = parseType();
		consume(TokenKind.RightParen);
		var fromTypes = [], toTypes = [];
		while (!check(TokenKind.LeftBrace) && !recoveringAtEnd()) {
			var conversion = consume(TokenKind.Identifier);
			if (conversion.text != "from" && conversion.text != "to")
				fail(conversion, 'Expected "from" or "to"');
			var conversionType = parseType();
			if (conversion.text == "from")
				fromTypes.push(conversionType);
			else
				toTypes.push(conversionType);
		}
		if (recovering && isDeclarationBoundary(current())) {
			recordExpected("enum abstract body");
			return {
				name: name,
				underlying: underlying,
				fromTypes: fromTypes,
				toTypes: toTypes,
				values: [],
				span: start.merge(previous().span)
			};
		}
		consume(TokenKind.LeftBrace);
		var values = [], bodyStart = position;
		while (!check(TokenKind.RightBrace) && !recoveringAtEnd()) {
			var valueStart = position;
			try {
				match(TokenKind.Var);
				var valueName = consumeName();
				consume(TokenKind.Assign);
				var value = parseExpression(),
					end = consume(TokenKind.Semicolon).span;
				values.push({name: valueName.text, value: value, span: valueName.span.merge(end)});
			} catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				synchronizeEnumAbstractValue(bodyStart, valueStart);
			}
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
		var name = consumeDeclarationName("typedef"),
			typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeParameters = parseTypeParameters(typeConstraints);
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
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			type: type,
			isPrivate: isPrivate,
			span: start.merge(end)
		};
	}

	function parseEnum(start:SourceSpan, metadata:Array<compiler.syntax.Ast.AstMetadata>):AstEnum {
		var name = consumeDeclarationName("enum"), typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeParameters = parseTypeParameters(typeConstraints), cases = [];
		if (recovering && isDeclarationBoundary(current())) {
			recordExpected("enum body");
			return {
				name: name,
				typeParameters: typeParameters,
				typeConstraints: typeConstraints,
				cases: cases,
				span: start.merge(previous().span)
			};
		}
		consume(TokenKind.LeftBrace);
		var bodyStart = position;
		while (!check(TokenKind.RightBrace) && !recoveringAtEnd()) {
			var caseStart = position;
			try {
				var caseMetadata = parseMetadata(),
					caseToken = consumeName(),
					params:Array<compiler.syntax.Ast.AstEnumParameter> = [];
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
				cases.push({
					name: caseToken.text,
					metadata: caseMetadata,
					params: params,
					span: caseToken.span.merge(previous().span)
				});
				consume(TokenKind.Semicolon);
			} catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				synchronizeEnumCase(bodyStart, caseStart);
			}
		}
		var end = consume(TokenKind.RightBrace).span;
		return {
			name: name,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			metadata: metadata,
			cases: cases,
			span: start.merge(end)
		};
	}

	function parseQualifiedName(allowWildcard:Bool = false):String {
		if (recovering && isExpressionTerminator(current().kind)) {
			var span = new SourceSpan(current().span.file, current().span.start, current().span.start);
			recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", "Expected name", span));
			return "";
		}
		var name = consumeName().text;
		while (check(TokenKind.Dot)) {
			if (allowWildcard && peekKind(1) == TokenKind.Star) {
				advance();
				advance();
				return name + ".*";
			}
			if (recovering && (isExpressionTerminator(peekKind(1)) || isDeclarationBoundary(tokens[position + 1])))
				break;
			advance();
			name += "." + consumeName().text;
		}
		return name;
	}

	function parseFunction(allowMissingReturn:Bool, isExtern:Bool = false, ?metadata:Array<compiler.syntax.Ast.AstMetadata>):AstFunction {
		var start = consume(TokenKind.Function).span,
			name = check(TokenKind.New) ? advance().text : consumeDeclarationName("function");
		return parseFunctionBody(start, name, allowMissingReturn, false, isExtern, metadata);
	}

	function parseFunctionBody(start:SourceSpan, name:String, allowMissingReturn:Bool, isStatic:Bool = false, isExtern:Bool = false,
			?metadata:Array<compiler.syntax.Ast.AstMetadata>):AstFunction {
		var typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeParameters = parseTypeParameters(typeConstraints);
		var arguments = [];
		if (recovering && (recoveringAtEnd() || isDeclarationBoundary(current())))
			recordExpected("left parenthesis");
		else {
			consume(TokenKind.LeftParen);
			while (!check(TokenKind.RightParen) && !recoveringAtEnd() && !canInsert(TokenKind.RightParen)) {
				if (check(TokenKind.Comma)) {
					recordExpected("parameter");
					advance();
					continue;
				}
				var optional = match(TokenKind.Question),
					argumentToken = consumeDeclarationToken("parameter");
				var argumentType = match(TokenKind.Colon) ? parseType() : InferredType,
					defaultValue = match(TokenKind.Assign) ? parseExpression() : null;
				arguments.push({
					name: argumentToken.text,
					type: argumentType,
					span: argumentToken.span.merge(previous().span),
					optional: optional || defaultValue != null,
					defaultValue: defaultValue
				});
				if (!match(TokenKind.Comma))
					break;
			}
			consume(TokenKind.RightParen);
		}
		var result = match(TokenKind.Colon) ? parseType() : allowMissingReturn && name == "new" ? VoidType : InferredType;
		var statements = [], end:SourceSpan;
		if (isExtern) {
			end = consume(TokenKind.Semicolon).span;
		} else if (match(TokenKind.LeftBrace)) {
			var bodyStart = position;
			while (!check(TokenKind.RightBrace) && !check(TokenKind.Eof)) {
				var statementStart = position;
				try
					appendStatements(statements, parseStatements())
				catch (error:CompileError) {
					if (!recovering)
						throw error;
					recordRecoveryDiagnostic(error.diagnostic);
					statements.push(ErrorStatement(error.diagnostic.span));
					synchronizeStatement(bodyStart, statementStart);
				}
			}
			end = consume(TokenKind.RightBrace).span;
		} else if (recoveringAtEnd()) {
			missingFunctionBody();
			end = current().span;
		} else if (recovering && isDeclarationBoundary(current())) {
			missingFunctionBody();
			end = current().span;
		} else {
			appendStatements(statements, parseStatements());
			end = statementSpan(statements[statements.length - 1]);
		}
		return {
			name: name,
			isStatic: isStatic,
			isExtern: isExtern,
			metadata: metadata == null ? [] : metadata,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			arguments: arguments,
			result: result,
			statements: statements,
			span: start.merge(end)
		};
	}

	function parseSwitchCaseBody():Array<AstStatement> {
		var statements:Array<AstStatement> = [], bodyStart = position;
		while (!check(TokenKind.RightBrace) && !check(TokenKind.Case) && !check(TokenKind.Default) && !check(TokenKind.Eof)) {
			var statementStart = position;
			try {
				appendStatements(statements, parseStatements());
			}
			catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				statements.push(ErrorStatement(error.diagnostic.span));
				synchronizeStatement(bodyStart, statementStart, true);
			}
		}
		return statements;
	}

	function synchronizeStatement(bodyStart:Int, statementStart:Int, stopAtSwitchBoundary:Bool = false, stopAtCatch:Bool = false,
		stopAtWhile:Bool = false):Void {
		var braceDepth = 0;
		for (index in bodyStart...position)
			switch tokens[index].kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				default:
			}
		if (position <= statementStart && !check(TokenKind.Eof))
			advance();
		while (!check(TokenKind.Eof)) {
			if (braceDepth == 0 && (check(TokenKind.RightBrace)
				|| stopAtSwitchBoundary && (check(TokenKind.Case) || check(TokenKind.Default))
				|| stopAtCatch && check(TokenKind.Catch)
				|| stopAtWhile && check(TokenKind.While)))
				return;
			var consumed = advance().kind;
			switch consumed {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				case TokenKind.Semicolon:
					if (braceDepth == 0)
						return;
				default:
			}
		}
	}

	function synchronizeObjectField():Void {
		var braceDepth = 0, bracketDepth = 0, parenDepth = 0;
		while (!check(TokenKind.Eof)) {
			if (braceDepth == 0 && bracketDepth == 0 && parenDepth == 0
				&& (check(TokenKind.Comma) || check(TokenKind.RightBrace)))
				return;
			switch advance().kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				case TokenKind.LeftBracket:
					bracketDepth++;
				case TokenKind.RightBracket:
					if (bracketDepth > 0)
						bracketDepth--;
				case TokenKind.LeftParen:
					parenDepth++;
				case TokenKind.RightParen:
					if (parenDepth > 0)
						parenDepth--;
				default:
			}
		}
	}

	function parseDelimitedExpression(endKind:TokenKind, allowAssign:Bool):AstExpression {
		try {
			var expression = parseExpression();
			if (recovering && !check(TokenKind.Comma) && !check(endKind)
				&& (!allowAssign || !check(TokenKind.Assign))) {
				recordExpected('comma or $endKind');
				synchronizeDelimited(endKind);
			}
			return expression;
		}
		catch (error:CompileError) {
			if (!recovering)
				throw error;
			recordRecoveryDiagnostic(error.diagnostic);
			synchronizeDelimited(endKind);
			return ErrorExpression(error.diagnostic.span);
		}
	}

	function synchronizeDelimited(endKind:TokenKind):Void {
		var braceDepth = 0, bracketDepth = 0, parenDepth = 0;
		while (!check(TokenKind.Eof)) {
			if (braceDepth == 0 && bracketDepth == 0 && parenDepth == 0
				&& (check(TokenKind.Comma) || check(endKind) || check(TokenKind.Semicolon)
					|| check(TokenKind.RightParen) || isDeclarationBoundary(current())))
				return;
			switch advance().kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				case TokenKind.LeftBracket:
					bracketDepth++;
				case TokenKind.RightBracket:
					if (bracketDepth > 0)
						bracketDepth--;
				case TokenKind.LeftParen:
					parenDepth++;
				case TokenKind.RightParen:
					if (parenDepth > 0)
						parenDepth--;
				default:
			}
		}
	}

	function parseDelimitedType(endKind:TokenKind):AstType {
		try {
			var type = parseType();
			if (recovering && !check(TokenKind.Comma) && !check(endKind)) {
				recordExpected('comma or $endKind');
				synchronizeTypeArgument();
			}
			return type;
		}
		catch (error:CompileError) {
			if (!recovering)
				throw error;
			recordRecoveryDiagnostic(error.diagnostic);
			synchronizeTypeArgument();
			return ErrorType(error.diagnostic.span);
		}
	}

	function synchronizeTypeArgument():Void {
		var angleDepth = 0, braceDepth = 0, bracketDepth = 0, parenDepth = 0;
		while (!check(TokenKind.Eof)) {
			if (angleDepth == 0 && braceDepth == 0 && bracketDepth == 0 && parenDepth == 0
				&& (check(TokenKind.Comma) || check(TokenKind.Greater) || check(TokenKind.Semicolon)
					|| check(TokenKind.RightParen) || check(TokenKind.RightBrace) || check(TokenKind.LeftBrace)
					|| isDeclarationBoundary(current())))
				return;
			switch advance().kind {
				case TokenKind.Less:
					angleDepth++;
				case TokenKind.Greater:
					if (angleDepth > 0)
						angleDepth--;
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				case TokenKind.LeftBracket:
					bracketDepth++;
				case TokenKind.RightBracket:
					if (bracketDepth > 0)
						bracketDepth--;
				case TokenKind.LeftParen:
					parenDepth++;
				case TokenKind.RightParen:
					if (parenDepth > 0)
						parenDepth--;
				default:
			}
		}
	}

	function parseTypeParameters(?constraints:Array<compiler.syntax.Ast.AstTypeConstraint>):Array<String> {
		var result = [];
		if (!match(TokenKind.Less))
			return result;
		while (!check(TokenKind.Greater) && !recoveringAtEnd()) {
			if (check(TokenKind.Comma)) {
				recordExpected("type parameter");
				advance();
				continue;
			}
			var parameter = consumeDeclarationToken("type parameter");
			if (result.indexOf(parameter.text) >= 0)
				fail(parameter, 'Duplicate type parameter "${parameter.text}"');
			result.push(parameter.text);
			if (match(TokenKind.Colon)) {
				var grouped = match(TokenKind.LeftParen);
				do {
					var constraint = parseType();
					if (constraints != null)
						constraints.push({parameter: parameter.text, type: constraint, span: parameter.span.merge(previous().span)});
				} while (grouped && match(TokenKind.Comma));
				if (grouped)
					consume(TokenKind.RightParen);
			}
			if (!match(TokenKind.Comma))
				break;
		}
		consume(TokenKind.Greater);
		return result;
	}

	function parseTypeArguments():Array<AstType> {
		var result = [];
		if (!match(TokenKind.Less))
			return result;
		if (recovering && (isExpressionTerminator(current().kind) || isDeclarationBoundary(current())))
			result.push(missingType("type argument"));
		else {
			while (!check(TokenKind.Greater) && !recoveringAtEnd()) {
				result.push(parseDelimitedType(TokenKind.Greater));
				if (!match(TokenKind.Comma) || check(TokenKind.Greater))
					break;
			}
		}
		consume(TokenKind.Greater);
		return result;
	}

	function parseClass(isPrivate:Bool, metadata:Array<compiler.syntax.Ast.AstMetadata>, isExtern:Bool = false):AstClass {
		var start = consume(TokenKind.Class).span,
			name = consumeDeclarationName("class"),
			typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeParameters = parseTypeParameters(typeConstraints),
			base:Null<AstType> = null,
			interfaces = [];
		if (match(TokenKind.Extends))
			base = recovering && (check(TokenKind.LeftBrace) || isDeclarationBoundary(current())) ? missingType("base type") : parseType();
		while (match(TokenKind.Implements)) {
			interfaces.push(recovering
				&& (check(TokenKind.LeftBrace) || isDeclarationBoundary(current())) ? missingType("implemented type") : parseType());
			while (match(TokenKind.Comma))
				interfaces.push(recovering
					&& (check(TokenKind.LeftBrace) || isDeclarationBoundary(current())) ? missingType("implemented type") : parseType());
		}
		if (recovering && isDeclarationBoundary(current())) {
			recordExpected("class body");
			return {
				name: name,
				isExtern: isExtern,
				typeParameters: typeParameters,
				typeConstraints: typeConstraints,
				isPrivate: isPrivate,
				metadata: metadata,
				base: base,
				interfaces: interfaces,
				fields: [],
				methods: [],
				span: start.merge(previous().span)
			};
		}
		consume(TokenKind.LeftBrace);
		var fields = [], methods = [], bodyStart = position;
		while (!check(TokenKind.RightBrace) && !check(TokenKind.Eof)) {
			var memberStart = position;
			try {
				var memberMetadata = parseMetadata();
				if (isMacroModifier()) {
					skipMacroFunction();
					continue;
				}
				var isStatic = false, isInline = false, isFinal = false;
				while (true) {
					if (current().kind == TokenKind.Identifier && current().text == "override") {
						advance();
						continue;
					}
					switch current().kind {
						case TokenKind.Public, TokenKind.Private:
							advance();
						case TokenKind.Static:
							advance();
							isStatic = true;
						case TokenKind.Inline:
							advance();
							isInline = true;
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
						methodName = check(TokenKind.New) ? advance().text : consumeDeclarationName("method");
					methods.push(parseFunctionBody(functionStart, methodName, true, isStatic, isExtern, memberMetadata));
				} else {
					var fieldStart = current().span;
					match(TokenKind.Var);
					var fieldName = consumeDeclarationName("field");
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
						metadata: memberMetadata,
						type: fieldType,
						initializer: initializer,
						readAccess: readAccess,
						writeAccess: writeAccess,
						isStatic: isStatic,
						isInline: isInline,
						isFinal: isFinal,
						span: fieldStart.merge(end)
					});
				}
			} catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				synchronizeClassMember(bodyStart, memberStart);
			}
		}
		var end = consume(TokenKind.RightBrace).span;
		return {
			name: name,
			isExtern: isExtern,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			isPrivate: isPrivate,
			metadata: metadata,
			base: base,
			interfaces: interfaces,
			fields: fields,
			methods: methods,
			span: start.merge(end)
		};
	}

	inline function isMacroModifier():Bool
		return check(TokenKind.Identifier) && current().text == "macro";

	/** Macro declarations are compile-time only; retain their source tokens but omit them from the runtime AST. */
	function skipMacroFunction():Void {
		advance();
		while (check(TokenKind.Public) || check(TokenKind.Private) || check(TokenKind.Static) || check(TokenKind.Inline) || check(TokenKind.Final))
			advance();
		if (!match(TokenKind.Function))
			fail(current(), "Macro modifier requires a function declaration");
		var parentheses = 0, brackets = 0, bodyDepth = 0;
		while (!check(TokenKind.Eof)) {
			var token = advance();
			switch token.kind {
				case TokenKind.LeftParen:
					parentheses++;
				case TokenKind.RightParen:
					if (parentheses > 0)
						parentheses--;
				case TokenKind.LeftBracket:
					brackets++;
				case TokenKind.RightBracket:
					if (brackets > 0)
						brackets--;
				case TokenKind.LeftBrace if (parentheses == 0 && brackets == 0):
					bodyDepth = 1;
					while (bodyDepth > 0 && !check(TokenKind.Eof))
						switch advance().kind {
							case TokenKind.LeftBrace: bodyDepth++;
							case TokenKind.RightBrace: bodyDepth--;
							default:
						}
					if (bodyDepth != 0)
						fail(token, "Unclosed macro function body");
					return;
				case TokenKind.Semicolon if (parentheses == 0 && brackets == 0):
					return;
				case TokenKind.RightBrace if (parentheses == 0 && brackets == 0):
					fail(token, "Macro modifier requires a function declaration");
				default:
			}
		}
		fail(previous(), "Unclosed macro function declaration");
	}

	function synchronizeClassMember(bodyStart:Int, memberStart:Int):Void {
		var braceDepth = 0;
		for (index in bodyStart...position)
			switch tokens[index].kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				default:
			}
		if (position <= memberStart && !check(TokenKind.Eof))
			advance();
		while (!check(TokenKind.Eof)) {
			if (braceDepth == 0 && (check(TokenKind.RightBrace) || isClassMemberStart(current())))
				return;
			switch advance().kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				default:
			}
		}
	}

	function synchronizeAbstractMember(bodyStart:Int, memberStart:Int):Void {
		var braceDepth = 0;
		for (index in bodyStart...position)
			switch tokens[index].kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				default:
			}
		if (position <= memberStart && !check(TokenKind.Eof))
			advance();
		while (!check(TokenKind.Eof)) {
			if (braceDepth == 0 && (check(TokenKind.RightBrace) || isAbstractMemberStart(current())))
				return;
			switch advance().kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				case TokenKind.Semicolon:
					if (braceDepth == 0)
						return;
				default:
			}
		}
	}

	static function isAbstractMemberStart(token:Token):Bool
		return switch token.kind {
			case TokenKind.Function, TokenKind.Public, TokenKind.Private, TokenKind.Static, TokenKind.Inline, TokenKind.At: true;
			default: false;
		};

	function synchronizeEnumCase(bodyStart:Int, caseStart:Int):Void {
		var braceDepth = 0;
		for (index in bodyStart...position)
			switch tokens[index].kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				default:
			}
		if (position <= caseStart && !check(TokenKind.Eof))
			advance();
		while (!check(TokenKind.Eof)) {
			if (braceDepth == 0 && check(TokenKind.RightBrace))
				return;
			switch advance().kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				case TokenKind.Semicolon:
					if (braceDepth == 0)
						return;
				default:
			}
		}
	}

	function synchronizeInterfaceMember(bodyStart:Int, memberStart:Int):Void {
		var braceDepth = 0;
		for (index in bodyStart...position)
			switch tokens[index].kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				default:
			}
		if (position <= memberStart && !check(TokenKind.Eof))
			advance();
		while (!check(TokenKind.Eof)) {
			if (braceDepth == 0 && (check(TokenKind.RightBrace) || check(TokenKind.Function)))
				return;
			switch advance().kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				case TokenKind.Semicolon:
					if (braceDepth == 0)
						return;
				default:
			}
		}
	}

	function synchronizeEnumAbstractValue(bodyStart:Int, valueStart:Int):Void {
		var braceDepth = 0;
		for (index in bodyStart...position)
			switch tokens[index].kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				default:
			}
		if (position <= valueStart && !check(TokenKind.Eof))
			advance();
		while (!check(TokenKind.Eof)) {
			if (braceDepth == 0 && (check(TokenKind.RightBrace) || isEnumAbstractValueStart(current())))
				return;
			switch advance().kind {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				case TokenKind.Semicolon:
					if (braceDepth == 0)
						return;
				default:
			}
		}
	}

	static function isEnumAbstractValueStart(token:Token):Bool
		return token.kind == TokenKind.Var || isNameToken(token.kind);

	static function isClassMemberStart(token:Token):Bool
		return switch token.kind {
			case TokenKind.Function, TokenKind.Var, TokenKind.Public, TokenKind.Private, TokenKind.Static, TokenKind.Inline, TokenKind.Final, TokenKind.At,
				TokenKind.Identifier: true;
			default: false;
		};

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
		var start = consume(TokenKind.Interface).span, name = consumeDeclarationName("interface"),
			typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [], typeParameters = parseTypeParameters(typeConstraints), bases = [];
		if (match(TokenKind.Extends)) {
			bases.push(recovering
				&& (check(TokenKind.LeftBrace) || isDeclarationBoundary(current())) ? missingType("base interface type") : parseType());
			while (match(TokenKind.Comma))
				bases.push(recovering
					&& (check(TokenKind.LeftBrace) || isDeclarationBoundary(current())) ? missingType("base interface type") : parseType());
		}
		if (recovering && isDeclarationBoundary(current())) {
			recordExpected("interface body");
			return {
				name: name,
				typeParameters: typeParameters,
				typeConstraints: typeConstraints,
				bases: bases,
				methods: [],
				span: start.merge(previous().span)
			};
		}
		consume(TokenKind.LeftBrace);
		var methods = [], bodyStart = position;
		while (!check(TokenKind.RightBrace) && !check(TokenKind.Eof)) {
			var memberStart = position;
			try {
				var methodMetadata = parseMetadata();
				while (check(TokenKind.Public) || check(TokenKind.Private) || check(TokenKind.Static) || check(TokenKind.Inline))
					advance();
				var methodToken = consume(TokenKind.Function),
					methodName = consumeDeclarationName("interface method");
				var typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
					typeParameters = parseTypeParameters(typeConstraints);
				var arguments = [];
				if (recovering && (recoveringAtEnd() || isDeclarationBoundary(current())))
					recordExpected("left parenthesis");
				else {
					consume(TokenKind.LeftParen);
					while (!check(TokenKind.RightParen) && !recoveringAtEnd() && !canInsert(TokenKind.RightParen)) {
						if (check(TokenKind.Comma)) {
							recordExpected("parameter");
							advance();
							continue;
						}
						var optional = match(TokenKind.Question),
							argumentName = consumeDeclarationName("parameter");
						consume(TokenKind.Colon);
						arguments.push({
							name: argumentName,
							type: parseType(),
							span: previous().span,
							optional: optional,
							defaultValue: null
						});
						if (!match(TokenKind.Comma))
							break;
					}
					consume(TokenKind.RightParen);
				}
				var result = match(TokenKind.Colon) ? parseType() : recovering ? missingType("interface method return type") : failType("Interface methods require a return type"),
					end = consume(TokenKind.Semicolon).span;
				methods.push({
					name: methodName,
					isStatic: false,
					isExtern: false,
					metadata: methodMetadata,
					typeParameters: typeParameters,
					typeConstraints: typeConstraints,
					arguments: arguments,
					result: result,
					statements: [],
					span: methodToken.span.merge(end)
				});
			} catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				synchronizeInterfaceMember(bodyStart, memberStart);
			}
		}
		var end = consume(TokenKind.RightBrace).span;
		return {
			name: name,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			bases: bases,
			methods: methods,
			span: start.merge(end)
		};
	}

	function parseStatement():AstStatement {
		if (match(TokenKind.Function)) {
			var start = previous().span,
				name = consumeDeclarationName("local function");
			consume(TokenKind.LeftParen);
			var arguments = [];
			if (!check(TokenKind.RightParen))
				do {
					var optional = match(TokenKind.Question),
						argument = consumeDeclarationToken("parameter"),
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
			var name = consumeDeclarationName("local");
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
				catches:Array<compiler.syntax.Ast.AstCatch> = [],
				end = previous().span;
			if (!check(TokenKind.Catch)) {
				if (!recovering)
					consume(TokenKind.Catch);
				recordExpected("catch clause");
			}
			while (check(TokenKind.Catch)) {
				var catchStart = consume(TokenKind.Catch).span;
				consume(TokenKind.LeftParen);
				var catchName = consumeDeclarationName("catch binding");
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
			}
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
				var caseStart = previous().span,
					values = expandPatternAlternatives(parseExpression());
				while (match(TokenKind.Comma))
					appendExpressions(values, expandPatternAlternatives(parseExpression()));
				var guard = parseSwitchGuard();
				consume(TokenKind.Colon);
				var statements = parseSwitchCaseBody();
				var caseEnd = statements.length == 0 ? expressionSpan(values[values.length - 1]) : statementSpan(statements[statements.length - 1]);
				for (value in values)
					cases.push({
						value: value,
						guard: guard,
						statements: statements,
						span: caseStart.merge(caseEnd)
					});
			}
			var defaultBranch = [], hasDefault = match(TokenKind.Default);
			if (hasDefault) {
				consume(TokenKind.Colon);
				defaultBranch = parseSwitchCaseBody();
			}
			var end = consume(TokenKind.RightBrace).span;
			if (match(TokenKind.Semicolon))
				end = previous().span;
			return Switch(expression, cases, defaultBranch, hasDefault, start.merge(end));
		}
		if (check(TokenKind.Identifier) || check(TokenKind.This)) {
			var saved = position, target = parseOr();
			if (match(TokenKind.Increment) || match(TokenKind.Decrement)) {
				var delta = previous().kind == TokenKind.Increment ? 1 : -1,
					end = consume(TokenKind.Semicolon).span;
				return switch target {
					case Variable(name, _):
						Increment(name, delta, expressionSpan(target).merge(end));
					default: throw new CompileError(new Diagnostic("E0002", "Increment target must be a variable", expressionSpan(target)));
				};
			}
			var assignmentKind = match(TokenKind.Assign) ? 0 : match(TokenKind.PlusAssign) ? 1 : match(TokenKind.MinusAssign) ? 2 : match(TokenKind.StarAssign) ? 3 : match(TokenKind.SlashAssign) ? 4 : match(TokenKind.PercentAssign) ? 5 : match(TokenKind.AndAssign) ? 6 : match(TokenKind.OrAssign) ? 7 : match(TokenKind.XorAssign) ? 8 : -1;
			if (assignmentKind >= 0) {
				var value = parseExpression(), end = expressionEnd(value);
				// Normalize compound lvalues before duplicating their read and write.
				// The generated bindings cannot collide with source identifiers.
				var span = expressionSpan(target).merge(end),
					bindings:Array<AstStatement> = [];
				if (assignmentKind != 0) {
					var stabilized = AssignmentTarget.stabilize(target, span, expressionSpan);
					target = stabilized.target;
					bindings = stabilized.bindings;
				}
				var operationSpan = expressionSpan(target).merge(expressionSpan(value)),
					assigned:AstExpression = switch assignmentKind {
						case 0: value;
						case 1: Add(target, value, operationSpan);
						case 2: Sub(target, value, operationSpan);
						case 3: Mul(target, value, operationSpan);
						case 4: Div(target, value, operationSpan);
						case 5: Mod(target, value, operationSpan);
						case 6: BitAnd(target, value, operationSpan);
						case 7: BitOr(target, value, operationSpan);
						default: BitXor(target, value, operationSpan);
					},
					assignment = switch target {
						case Variable(name, _): Assignment(name, assigned, expressionSpan(target).merge(end));
						case Index(array, offset, _): IndexAssignment(array, offset, assigned, expressionSpan(target).merge(end));
						case Member(object, field, _): FieldAssignment(object, field, assigned, expressionSpan(target).merge(end));
						default:
							throw new CompileError(new Diagnostic("E0002", "Assignment target must be a variable, field, or array element",
								expressionSpan(target)));
					};
				if (bindings.length == 0)
					return assignment;
				bindings.push(assignment);
				return Expression(BlockExpression(bindings, IntegerLiteral(0, span), span), span);
			}
			position = saved;
		}
		if (match(TokenKind.If)) {
			var start = previous().span;
			consume(TokenKind.LeftParen);
			var condition = parseExpression();
			consume(TokenKind.RightParen);
			var thenBranch = parseStatementOrBlock();
			var hasElse = match(TokenKind.Else),
				elseBranch = hasElse ? parseStatementOrBlock() : [];
			var end = statementEnd(hasElse ? elseBranch : thenBranch);
			return If(condition, thenBranch, elseBranch, start.merge(end));
		}
		if (match(TokenKind.While)) {
			var start = previous().span;
			consume(TokenKind.LeftParen);
			var condition = parseExpression();
			consume(TokenKind.RightParen);
			var body = parseStatementOrBlock();
			var end = statementEnd(body);
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
			var name = consumeDeclarationName("for binding"), valueName = null;
			if (match(TokenKind.Assign)) {
				consume(TokenKind.Greater);
				valueName = consumeDeclarationName("for value binding");
			}
			if (!match(TokenKind.In)) {
				if (!recovering || !isExpressionTerminator(current().kind))
					consume(TokenKind.In);
				recordExpected("in");
			}
			var iterable = parseExpression();
			consume(TokenKind.RightParen);
			var body = parseStatementOrBlock(), end = statementEnd(body);
			return ForIn(name, valueName, iterable, body, start.merge(end));
		}
		var expression = parseExpression(), end = expressionEnd(expression);
		return Expression(expression, expressionSpan(expression).merge(end));
	}

	function parseTryBody():Array<AstStatement> {
		if (check(TokenKind.LeftBrace))
			return parseStatementOrBlock();
		var bodyStart = position, expression:AstExpression;
		try {
			expression = parseExpression();
			if (recovering && !check(TokenKind.Semicolon) && !check(TokenKind.Catch)
				&& !check(TokenKind.RightBrace) && !check(TokenKind.Eof)) {
				recordExpected("semicolon or catch");
				synchronizeStatement(bodyStart, bodyStart, false, true);
			}
		}
		catch (error:CompileError) {
			if (!recovering)
				throw error;
			recordRecoveryDiagnostic(error.diagnostic);
			synchronizeStatement(bodyStart, bodyStart, false, true);
			return [ErrorStatement(error.diagnostic.span)];
		}
		match(TokenKind.Semicolon);
		return [Expression(expression, expressionSpan(expression))];
	}

	function parseDoWhileBody():Array<AstStatement> {
		if (check(TokenKind.LeftBrace))
			return parseStatementOrBlock();
		var bodyStart = position, expression:AstExpression;
		try {
			expression = parseExpression();
			if (recovering && !check(TokenKind.Semicolon) && !check(TokenKind.While)
				&& !check(TokenKind.RightBrace) && !check(TokenKind.Eof)) {
				recordExpected("semicolon or while");
				synchronizeStatement(bodyStart, bodyStart, false, false, true);
			}
		}
		catch (error:CompileError) {
			if (!recovering)
				throw error;
			recordRecoveryDiagnostic(error.diagnostic);
			synchronizeStatement(bodyStart, bodyStart, false, false, true);
			return [ErrorStatement(error.diagnostic.span)];
		}
		match(TokenKind.Semicolon);
		return [Expression(expression, expressionSpan(expression))];
	}

	function parseAnonymousFunctionBody():Array<AstStatement> {
		if (check(TokenKind.LeftBrace))
			return parseStatementOrBlock();
		var start = current().span;
		match(TokenKind.Return);
		var value = parseExpression();
		match(TokenKind.Semicolon);
		return [Return(value, start.merge(expressionSpan(value)))];
	}

	function parseArrowFunctionBody():Array<AstStatement> {
		if (check(TokenKind.LeftBrace))
			return parseStatementOrBlock();
		var value = parseExpression();
		return [Return(value, expressionSpan(value))];
	}

	function parseStatements():Array<AstStatement> {
		if (!check(TokenKind.Var))
			return [parseStatement()];
		var start = advance().span, declarations = [];
		do {
			var nameToken = consumeDeclarationToken("local"),
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
		var expression = parseNullCoalesce();
		if (match(TokenKind.Question)) {
			var whenTrue = parseExpressionBranch();
			consume(TokenKind.Colon);
			var whenFalse = parseExpressionBranch();
			expression = Conditional(expression, whenTrue, whenFalse, expressionSpan(expression).merge(expressionSpan(whenFalse)));
		}
		if (check(TokenKind.Assign) && peekKind(1) != TokenKind.Greater) {
			advance();
			var value = parseExpression(),
				span = expressionSpan(expression).merge(expressionSpan(value));
			expression = switch expression {
				case Variable(name, _): BlockExpression([Assignment(name, value, span)], Variable(name, span), span);
				default: throw new CompileError(new Diagnostic("E0002", "Assignment expression target must be a variable", expressionSpan(expression)));
			};
		}
		return expression;
	}

	function parseNullCoalesce():AstExpression {
		var expression = parseOr();
		if (check(TokenKind.Dot) && peekKind(1) == TokenKind.Dot && peekKind(2) == TokenKind.Dot) {
			advance();
			advance();
			advance();
			var end = parseOr();
			expression = Range(expression, end, expressionSpan(expression).merge(expressionSpan(end)));
		}
		if (match(TokenKind.NullCoalesce)) {
			var fallback = parseNullCoalesce(),
				span = expressionSpan(expression).merge(expressionSpan(fallback)),
				localName = '$' + 'null-coalesce:${span.start}',
				local = Variable(localName, expressionSpan(expression));
			return BlockExpression([VarDeclaration(localName, null, expression, expressionSpan(expression))],
				Conditional(Equal(local, NullLiteral(expressionSpan(local)), expressionSpan(local)), fallback, local, span), span);
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
		var expression = parseComparison();
		while (match(TokenKind.AndAnd)) {
			var right = parseComparison(),
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
		var expression = parseShift();
		while (match(TokenKind.Ampersand)) {
			var right = parseShift();
			expression = BitAnd(expression, right, expressionSpan(expression).merge(expressionSpan(right)));
		}
		return expression;
	}

	function parseComparison():AstExpression {
		var expression = parseBitOr();
		if (check(TokenKind.Less) || check(TokenKind.LessEqual) || check(TokenKind.Greater) || check(TokenKind.GreaterEqual) || check(TokenKind.EqualEqual)
			|| check(TokenKind.NotEqual)) {
			var operation = advance().kind;
			var right = parseBitOr();
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
		if (recovering && isExpressionTerminator(current().kind)) {
			var span = new SourceSpan(current().span.file, current().span.start, current().span.start);
			recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", "Expected expression", span));
			return ErrorExpression(span);
		}
		if (check(TokenKind.At)) {
			parseMetadata();
			return parsePrimary();
		}
		if (match(TokenKind.Switch))
			return parseSwitchExpression(previous().span);
		if (match(TokenKind.Try))
			return parseTryExpression(previous().span);
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
						argument = consumeDeclarationToken("parameter"),
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
		if (check(TokenKind.Identifier) && peekKind(1) == TokenKind.Arrow) {
			var argument = advance(), start = argument.span;
			advance();
			var arguments:Array<AstArgument> = [
				{
					name: argument.text,
					type: InferredType,
					span: argument.span,
					optional: false,
					defaultValue: null
				}
			], body = parseArrowFunctionBody();
			return Lambda(arguments, body, start.merge(body.length == 0 ? previous().span : statementSpan(body[body.length - 1])));
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
			var start = previous().span;
			if (match(TokenKind.Integer)) {
				var token = previous(), value = parseIntegerToken(token, true);
				return parsePostfix(IntegerLiteral(value, start.merge(token.span)));
			}
			var value = parsePrimary();
			return Negate(value, start.merge(expressionSpan(value)));
		}
		if (match(TokenKind.Not)) {
			var start = previous().span, value = parsePrimary();
			return Not(value, start.merge(expressionSpan(value)));
		}
		if (match(TokenKind.BitNot)) {
			var start = previous().span, value = parsePrimary();
			return BitXor(value, IntegerLiteral(-1, start), start.merge(expressionSpan(value)));
		}
		if (match(TokenKind.Integer)) {
			var token = previous();
			return parsePostfix(IntegerLiteral(parseIntegerToken(token), token.span));
		}
		if (match(TokenKind.Float))
			return parsePostfix(FloatLiteral(Std.parseFloat(previous().text), previous().span));
		if (match(TokenKind.StringLiteral))
			return parsePostfix(parseStringExpression(previous()));
		if (match(TokenKind.RegexLiteral)) {
			var token = previous(),
				delimiter = token.text.lastIndexOf("/"),
				pattern = StringTools.replace(token.text.substring(2, delimiter), "\\/", "/"),
				options = token.text.substring(delimiter + 1);
			return parsePostfix(New("EReg", [StringLiteral(pattern, token.span), StringLiteral(options, token.span)], token.span));
		}
		if (match(TokenKind.BoolTrue))
			return parsePostfix(BoolLiteral(true, previous().span));
		if (match(TokenKind.BoolFalse))
			return parsePostfix(BoolLiteral(false, previous().span));
		if (match(TokenKind.LeftBracket)) {
			var start = previous().span, values = [];
			if (match(TokenKind.For)) {
				consume(TokenKind.LeftParen);
				var keyName = consumeDeclarationName("comprehension key"),
					valueName = null;
				if (match(TokenKind.Assign)) {
					consume(TokenKind.Greater);
					valueName = consumeDeclarationName("comprehension value");
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
				var value = parseComprehensionValue();
				if (match(TokenKind.Assign)) {
					consume(TokenKind.Greater);
					var mapValue = parseComprehensionValue(),
						end = consume(TokenKind.RightBracket).span;
					return parsePostfix(MapComprehension(keyName, valueName, iterable, condition, value, mapValue, start.merge(end)));
				}
				var end = consume(TokenKind.RightBracket).span;
				return parsePostfix(ArrayComprehension(keyName, valueName, iterable, condition, value, start.merge(end)));
			}
			if (!check(TokenKind.RightBracket)) {
				var first = parseDelimitedExpression(TokenKind.RightBracket, true);
				if (match(TokenKind.Assign)) {
					consume(TokenKind.Greater);
					var entries = [], value = parseDelimitedExpression(TokenKind.RightBracket, false);
					entries.push({key: first, value: value, span: expressionSpan(first).merge(expressionSpan(value))});
					while (match(TokenKind.Comma)) {
						if (check(TokenKind.RightBracket))
							break;
						var key = parseDelimitedExpression(TokenKind.RightBracket, true);
						consume(TokenKind.Assign);
						consume(TokenKind.Greater);
						var entryValue = parseDelimitedExpression(TokenKind.RightBracket, false);
						entries.push({key: key, value: entryValue, span: expressionSpan(key).merge(expressionSpan(entryValue))});
					}
					var end = consume(TokenKind.RightBracket).span;
					return parsePostfix(MapLiteral(entries, start.merge(end)));
				}
				values.push(first);
				while (match(TokenKind.Comma))
					if (!check(TokenKind.RightBracket))
						values.push(parseDelimitedExpression(TokenKind.RightBracket, false));
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
			if (check(TokenKind.Identifier) && current().text == "List") {
				advance();
				var typeArguments = check(TokenKind.Less) ? parseTypeArguments() : [];
				if (isRecoveryBoundary()) {
					recordExpected("left parenthesis");
					var missingEnd = current().span;
					return parsePostfix(typeArguments.length > 0
						? NewArray(typeArguments[0], IntegerLiteral(0, missingEnd), start.merge(missingEnd))
						: ArrayLiteral([], start.merge(missingEnd)));
				}
				consume(TokenKind.LeftParen);
				var end = consume(TokenKind.RightParen).span;
				if (typeArguments.length > 0) {
					if (typeArguments.length != 1)
						fail(previous(), 'List expects 1 type argument, got ${typeArguments.length}');
					return parsePostfix(NewArray(typeArguments[0], IntegerLiteral(0, end), start.merge(end)));
				}
				return parsePostfix(ArrayLiteral([], start.merge(end)));
			}
			if (check(TokenKind.Identifier) && current().text == "Array") {
				advance();
				if (match(TokenKind.LeftParen)) {
					var end = consume(TokenKind.RightParen).span;
					return parsePostfix(ArrayLiteral([], start.merge(end)));
				}
				if (isRecoveryBoundary()) {
					recordExpected("type arguments or left parenthesis");
					var missingEnd = current().span;
					return parsePostfix(ArrayLiteral([], start.merge(missingEnd)));
				}
				consume(TokenKind.Less);
				var element = parseType();
				consume(TokenKind.Greater);
				if (isRecoveryBoundary()) {
					recordExpected("left parenthesis");
					var missingEnd = current().span;
					return parsePostfix(NewArray(element, ErrorExpression(missingEnd), start.merge(missingEnd)));
				}
				consume(TokenKind.LeftParen);
				var length = parseExpression();
				var end = consume(TokenKind.RightParen).span;
				return parsePostfix(NewArray(element, length, start.merge(end)));
			}
			if (check(TokenKind.Identifier) && current().text == "Map") {
				advance();
				if (match(TokenKind.LeftParen)) {
					var end = consume(TokenKind.RightParen).span;
					return parsePostfix(MapLiteral([], start.merge(end)));
				}
				if (isRecoveryBoundary()) {
					recordExpected("type arguments or left parenthesis");
					var missingEnd = current().span;
					return parsePostfix(MapLiteral([], start.merge(missingEnd)));
				}
				consume(TokenKind.Less);
				var key = parseType();
				var value = if (match(TokenKind.Comma))
					parseType();
				else if (isRecoveryBoundary() || check(TokenKind.Greater)) {
					recordExpected("comma");
					missingType("map value");
				} else {
					consume(TokenKind.Comma);
					parseType();
				};
				consume(TokenKind.Greater);
				if (isRecoveryBoundary()) {
					recordExpected("left parenthesis");
					var missingEnd = current().span;
					return parsePostfix(NewMap(key, value, start.merge(missingEnd)));
				}
				consume(TokenKind.LeftParen);
				var end = consume(TokenKind.RightParen).span;
				return parsePostfix(NewMap(key, value, start.merge(end)));
			}
			var typeName = parseQualifiedName();
			var typeArguments = parseTypeArguments();
			if (recovering && (recoveringAtEnd() || isDeclarationBoundary(current()))) {
				recordExpected("left parenthesis");
				var end = current().span;
				return parsePostfix(typeArguments.length == 0 ? New(typeName, [],
					start.merge(end)) : NewGeneric(typeName, typeArguments, [], start.merge(end)));
			}
			consume(TokenKind.LeftParen);
			var arguments = [];
			if (!check(TokenKind.RightParen)) {
				do
					arguments.push(parseDelimitedExpression(TokenKind.RightParen, false)) while (match(TokenKind.Comma));
			}
			var end = consume(TokenKind.RightParen).span;
			return parsePostfix(typeArguments.length == 0 ? New(typeName, arguments,
				start.merge(end)) : NewGeneric(typeName, typeArguments, arguments, start.merge(end)));
		}
		if (check(TokenKind.LeftParen)) {
			var saved = position,
				start = current().span,
				isLambda = parenthesizedLambdaAhead();
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
						argumentName = consumeDeclarationName("parameter");
					var argumentType = match(TokenKind.Colon) ? parseType() : InferredType;
					arguments.push({
						name: argumentName,
						type: argumentType,
						span: argumentStart.merge(previous().span),
						optional: optional,
						defaultValue: null
					});
				} while (match(TokenKind.Comma));
			}
			consume(TokenKind.RightParen);
			if (match(TokenKind.Arrow)) {
				var body = parseArrowFunctionBody();
				return Lambda(arguments, body, start.merge(body.length == 0 ? previous().span : statementSpan(body[body.length - 1])));
			}
			position = saved;
			advance();
			var grouped = parseExpression();
			consume(TokenKind.Colon);
			var target = parseType(), end = consume(TokenKind.RightParen).span;
			return parsePostfix(Cast(grouped, target, start.merge(end)));
		}
		if (match(TokenKind.This)) {
			var start = previous().span, end = start, name = "this";
			while (check(TokenKind.Dot)
				&& peekKind(1) != TokenKind.Dot
				&& !(recovering && (isExpressionTerminator(peekKind(1)) || isDeclarationBoundary(tokens[position + 1])))) {
				advance();
				var part = consumeName();
				name += "." + part.text;
				end = part.span;
			}
			var expression:AstExpression = Variable(name, start.merge(end));
			return parsePostfix(expression);
		}
		if (match(TokenKind.LeftBrace)) {
			var start = previous().span, fields = [];
			if (!check(TokenKind.RightBrace)) {
				while (!check(TokenKind.RightBrace) && !check(TokenKind.Eof)) {
					var fieldName = "<missing>", fieldStart = current().span;
					try {
						var name = consumeDeclarationToken("object field");
						fieldName = name.text;
						fieldStart = name.span;
						consume(TokenKind.Colon);
						var value = parseExpression();
						fields.push({name: name.text, value: value, span: name.span.merge(expressionSpan(value))});
					}
					catch (error:CompileError) {
						if (!recovering)
							throw error;
						recordRecoveryDiagnostic(error.diagnostic);
						fields.push({name: fieldName, value: ErrorExpression(error.diagnostic.span), span: fieldStart.merge(error.diagnostic.span)});
					synchronizeObjectField();
					}
					if (!match(TokenKind.Comma))
						break;
				}
			}
			var end = consume(TokenKind.RightBrace).span;
			return parsePostfix(ObjectLiteral(fields, start.merge(end)));
		}
		if (check(TokenKind.Identifier)
			&& peekKind(1) == TokenKind.Less
			&& (current().text == "sizeof" || current().text == "alignof" || current().text == "offsetof"))
			return parseNativeLayoutQuery();
		if (isNameToken(current().kind)) {
			var nameToken = consumeName(), name = nameToken.text, start = nameToken.span, end = start;
			while (check(TokenKind.Dot)
				&& peekKind(1) != TokenKind.Dot
				&& !(recovering && (isExpressionTerminator(peekKind(1)) || isDeclarationBoundary(tokens[position + 1])))) {
				advance();
				var part = consumeName();
				name += "." + part.text;
				end = part.span;
			}
			var expression:AstExpression = Variable(name, start.merge(end));
			if (match(TokenKind.LeftParen)) {
				var arguments = [];
				if (!check(TokenKind.RightParen)) {
					do
						arguments.push(parseDelimitedExpression(TokenKind.RightParen, false)) while (match(TokenKind.Comma));
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

	function parseNativeLayoutQuery():AstExpression {
		var name = consume(TokenKind.Identifier), kind = switch name.text {
			case "sizeof": SizeOf;
			case "alignof": AlignOf;
			case "offsetof": OffsetOf;
			default: throw "Invalid native layout query";
		};
		consume(TokenKind.Less);
		var type = parseType();
		consume(TokenKind.Greater);
		consume(TokenKind.LeftParen);
		var field:Null<String> = null;
		if (kind == OffsetOf) {
			var token = consume(TokenKind.StringLiteral);
			field = decodeString(token.text);
		}
		var end = consume(TokenKind.RightParen).span;
		return parsePostfix(NativeLayoutQuery(kind, type, field, name.span.merge(end)));
	}

	static function isExpressionTerminator(kind:TokenKind):Bool
		return switch kind {
			case TokenKind.Semicolon, TokenKind.Comma, TokenKind.RightParen, TokenKind.RightBracket, TokenKind.RightBrace, TokenKind.Eof: true;
			default: false;
		};

	static function isDeclarationBoundary(token:Token):Bool
		return isTopLevelStart(token) || token.kind == TokenKind.RightBrace;

	function parenthesizedLambdaAhead():Bool {
		var depth = 0, cursor = position;
		while (cursor < tokens.length) {
			switch tokens[cursor].kind {
				case LeftParen:
					depth++;
				case RightParen:
					depth--;
					if (depth == 0)
						return cursor + 1 < tokens.length && tokens[cursor + 1].kind == TokenKind.Arrow;
				default:
			}
			cursor++;
		}
		return false;
	}

	function parseComprehensionValue():AstExpression {
		if (match(TokenKind.For))
			return parseNestedArrayComprehension(previous().span);
		if (check(TokenKind.LeftBrace) && !(peekKind(1) == TokenKind.Identifier && peekKind(2) == TokenKind.Colon))
			return parseExpressionBranch();
		return parseExpression();
	}

	function parseNestedArrayComprehension(start:SourceSpan):AstExpression {
		consume(TokenKind.LeftParen);
		var keyName = consumeDeclarationName("comprehension key"),
			valueName = null;
		if (match(TokenKind.Assign)) {
			consume(TokenKind.Greater);
			valueName = consumeDeclarationName("comprehension value");
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
		var value = parseComprehensionValue();
		return ArrayComprehension(keyName, valueName, iterable, condition, value, start.merge(expressionSpan(value)));
	}

	function parseExpressionBranch():AstExpression {
		if (!check(TokenKind.LeftBrace) || (peekKind(1) == TokenKind.Identifier && peekKind(2) == TokenKind.Colon))
			return parseExpression();
		advance();
		var start = previous().span, statements:Array<AstStatement> = [], bodyStart = position;
		while (!check(TokenKind.RightBrace) && !check(TokenKind.Eof)) {
			var statementStart = position;
			try {
				if (isStatementOnlyStart(current().kind)) {
					appendStatements(statements, parseStatements());
					continue;
				}
				if (check(TokenKind.LeftBrace) && !(peekKind(1) == TokenKind.Identifier && peekKind(2) == TokenKind.Colon)) {
					var result = parseExpressionBranch();
					match(TokenKind.Semicolon);
					if (check(TokenKind.RightBrace)) {
						var end = consume(TokenKind.RightBrace).span;
						return BlockExpression(statements, result, start.merge(end));
					}
					statements.push(Expression(result, expressionSpan(result)));
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
			catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				statements.push(ErrorStatement(error.diagnostic.span));
				synchronizeStatement(bodyStart, statementStart);
			}
		}
		var trailing = trailingBlockResult(statements);
		if (trailing != null) {
			var end = consume(TokenKind.RightBrace).span;
			return BlockExpression(trailing.statements, trailing.result, start.merge(end));
		}
		if (recoveringAtEnd()) {
			var span = current().span;
			recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", "Expression block requires a result expression", span));
			return ErrorExpression(span);
		}
		fail(current(), "Expression block requires a result expression");
		return null;
	}

	static function trailingBlockResult(statements:Array<AstStatement>):Null<{statements:Array<AstStatement>, result:AstExpression}> {
		if (statements.length == 0)
			return null;
		var last = statements[statements.length - 1],
			prefix = statements.slice(0, statements.length - 1);
		return switch last {
			case AstStatement.Expression(result, _): {statements: prefix, result: result};
			case AstStatement.If(predicate, whenTrue, whenFalse, span):
				if (whenFalse.length == 0)
					return null;
				var trueResult = trailingBlockResult(whenTrue),
					falseResult = trailingBlockResult(whenFalse);
				if (trueResult == null || falseResult == null)
					return null;
				{
					statements: prefix,
					result: Conditional(predicate, blockResultExpression(trueResult), blockResultExpression(falseResult), span)
				};
			case _: null;
		};
	}

	static function blockResultExpression(block:{statements:Array<AstStatement>, result:AstExpression}):AstExpression
		return block.statements.length == 0 ? block.result : BlockExpression(block.statements, block.result,
			statementSpan(block.statements[0]).merge(expressionSpan(block.result)));

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
			var caseStart = previous().span,
				values = expandPatternAlternatives(parseExpression());
			while (match(TokenKind.Comma))
				appendExpressions(values, expandPatternAlternatives(parseExpression()));
			var guard = parseSwitchGuard();
			consume(TokenKind.Colon);
			var result = parseSwitchExpressionBranch();
			for (value in values)
				cases.push({
					value: value,
					guard: guard,
					result: result,
					span: caseStart.merge(expressionSpan(result))
				});
		}
		var fallback = null;
		if (match(TokenKind.Default)) {
			consume(TokenKind.Colon);
			fallback = parseSwitchExpressionBranch();
		}
		var end = consume(TokenKind.RightBrace).span;
		return parsePostfix(SwitchExpression(subject, cases, fallback, start.merge(end)));
	}

	static function appendExpressions(target:Array<AstExpression>, values:Array<AstExpression>):Void
		for (value in values)
			target.push(value);

	static function expandPatternAlternatives(pattern:AstExpression):Array<AstExpression>
		return switch pattern {
			case BitOr(left, right, _):
				var values = expandPatternAlternatives(left);
				appendExpressions(values, expandPatternAlternatives(right));
				values;
			case ArrayLiteral(elements, span):
				var combinations:Array<Array<AstExpression>> = [[]];
				for (element in elements) {
					var expanded = expandPatternAlternatives(element),
						next:Array<Array<AstExpression>> = [];
					for (combination in combinations)
						for (alternative in expanded) {
							var copy = combination.copy();
							copy.push(alternative);
							next.push(copy);
						}
					combinations = next;
				}
				[for (combination in combinations) ArrayLiteral(combination, span)];
			case Call(name, arguments, span):
				expandCallPattern(name, arguments, span);
			case _: [pattern];
		};

	static function expandCallPattern(name:String, arguments:Array<AstExpression>, span:SourceSpan):Array<AstExpression> {
		var combinations:Array<Array<AstExpression>> = [[]];
		for (argument in arguments) {
			var expanded = expandPatternAlternatives(argument),
				next:Array<Array<AstExpression>> = [];
			for (combination in combinations)
				for (alternative in expanded) {
					var copy = combination.copy();
					copy.push(alternative);
					next.push(copy);
				}
			combinations = next;
		}
		return [for (arguments in combinations) Call(name, arguments, span)];
	}

	function parseTryExpression(start:SourceSpan):AstExpression {
		var value = parseExpressionBranch(),
			catches:Array<compiler.syntax.Ast.AstCatch> = [],
			end = expressionSpan(value);
		do {
			var catchStart = consume(TokenKind.Catch).span;
			consume(TokenKind.LeftParen);
			var name = consume(TokenKind.Identifier).text;
			consume(TokenKind.Colon);
			var type = parseType();
			consume(TokenKind.RightParen);
			var caught = parseExpressionBranch();
			end = expressionSpan(caught);
			catches.push({
				name: name,
				type: type,
				statements: [Return(caught, end)],
				span: catchStart.merge(end)
			});
		} while (check(TokenKind.Catch));
		var body = [
			compiler.syntax.Ast.AstStatement.Try([Return(value, expressionSpan(value))], catches, start.merge(end))
		], lambda = compiler.syntax.Ast.AstExpression.Lambda([], body, start.merge(end));
		return parsePostfix(ClosureCall(lambda, [], start.merge(end)));
	}

	function parseSwitchGuard():Null<AstExpression> {
		if (!match(TokenKind.If))
			return null;
		if (!match(TokenKind.LeftParen))
			return parseExpression();
		var guard = parseExpression();
		consume(TokenKind.RightParen);
		return guard;
	}

	function parseSwitchExpressionBranch():AstExpression {
		if (check(TokenKind.LeftBrace) && !(peekKind(1) == TokenKind.Identifier && peekKind(2) == TokenKind.Colon))
			return parseExpressionBranch();
		var statements:Array<AstStatement> = [], start = current().span, bodyStart = position;
		while (true) {
			var statementStart = position;
			try {
				if (atSwitchBranchEnd() && statements.length == 0)
					return EmptyExpression(start.merge(current().span));
				if (atSwitchBranchEnd() && statements.length > 0 && statementTerminates(statements[statements.length - 1])) {
					var end = statementSpan(statements[statements.length - 1]);
					return BlockExpression(statements, Unreachable(end), start.merge(end));
				}
				if (isStatementOnlyStart(current().kind)) {
					appendStatements(statements, parseStatements());
					continue;
				}
				if (check(TokenKind.LeftBrace) && !(peekKind(1) == TokenKind.Identifier && peekKind(2) == TokenKind.Colon)) {
					var result = parseExpressionBranch();
					match(TokenKind.Semicolon);
					if (atSwitchBranchEnd())
						return statements.length == 0 ? result : BlockExpression(statements, result, start.merge(expressionSpan(result)));
					statements.push(Expression(result, expressionSpan(result)));
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
			catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				statements.push(ErrorStatement(error.diagnostic.span));
				synchronizeStatement(bodyStart, statementStart, true);
				if (atSwitchBranchEnd()) {
					var end = error.diagnostic.span;
					return BlockExpression(statements, ErrorExpression(end), start.merge(end));
				}
			}
		}
	}

	function atSwitchBranchEnd():Bool
		return check(TokenKind.Case) || check(TokenKind.Default) || check(TokenKind.RightBrace) || recoveringAtEnd();

	static function statementTerminates(statement:AstStatement):Bool
		return switch statement {
			case Return(_, _), ReturnVoid(_), Throw(_, _), Break(_), Continue(_): true;
			case If(_, yes, no, _): yes.length > 0 && no.length > 0 && statementTerminates(yes[yes.length - 1]) && statementTerminates(no[no.length - 1]);
			default: false;
		};

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
					default: ClosureCall(expression, arguments, expressionSpan(expression).merge(end));
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
				if (recovering && (isExpressionTerminator(current().kind) || isDeclarationBoundary(current()))) {
					var span = new SourceSpan(current().span.file, current().span.start, current().span.start);
					recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", "Expected member name", span));
					expression = Member(expression, "", expressionSpan(expression).merge(span));
					break;
				}
				var nameToken = consumeName(), name = nameToken.text;
				if (match(TokenKind.LeftParen)) {
					var arguments = [];
					if (!check(TokenKind.RightParen)) {
						do
							arguments.push(parseDelimitedExpression(TokenKind.RightParen, false)) while (match(TokenKind.Comma));
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
				do {
					var optional = match(TokenKind.Question);
					if (check(TokenKind.Identifier) && peekKind(1) == TokenKind.Colon) {
						advance();
						advance();
					}
					var argument = parseType();
					arguments.push(optional ? NullableType(argument) : argument);
				} while (match(TokenKind.Comma));
			}
			consume(TokenKind.RightParen);
			consume(TokenKind.Arrow);
			return chainedFunctionType(arguments, parseType());
		}
		var atomic = parseAtomicType();
		if (match(TokenKind.Arrow))
			return chainedFunctionType(switch atomic {
				case VoidType: [];
				default: [atomic];
			}, parseType());
		return atomic;
	}

	static function chainedFunctionType(arguments:Array<AstType>, result:AstType):AstType
		return switch result {
			case FunctionType(nextArguments, finalResult): FunctionType(arguments.concat(nextArguments), finalResult);
			default: FunctionType(arguments, result);
		};

	function parseAtomicType():AstType {
		if (recovering && (isExpressionTerminator(current().kind) || isDeclarationBoundary(current()))) {
			var span = new SourceSpan(current().span.file, current().span.start, current().span.start);
			recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", "Expected type", span));
			return ErrorType(span);
		}
		if (match(TokenKind.LeftBrace)) {
			var fields = [];
			while (!check(TokenKind.RightBrace) && !check(TokenKind.Eof)) {
				var fieldName = "<missing>", fieldStart = current().span;
				try {
					var optional = false;
					for (metadata in parseMetadata())
						if (metadata.name == "optional")
							optional = true;
					while (check(TokenKind.Question) || check(TokenKind.Final) || check(TokenKind.Var))
						if (match(TokenKind.Question)) {
							if (optional)
								fail(previous(), "Duplicate optional field marker");
							optional = true;
						} else
							advance();
					var name = consumeDeclarationToken("anonymous field");
					fieldName = name.text;
					fieldStart = name.span;
					consume(TokenKind.Colon);
					var type = parseType();
					fields.push({
						name: name.text,
						type: type,
						optional: optional,
						span: name.span.merge(previous().span)
					});
				}
				catch (error:CompileError) {
					if (!recovering)
						throw error;
					recordRecoveryDiagnostic(error.diagnostic);
					fields.push({
						name: fieldName,
						type: ErrorType(error.diagnostic.span),
						optional: false,
						span: fieldStart.merge(error.diagnostic.span)
					});
						synchronizeObjectField();
				}
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
				if (isRecoveryBoundary())
					return ArrayType(missingType("type arguments"));
				consume(TokenKind.Less);
				var element = parseType();
				consume(TokenKind.Greater);
				return ArrayType(element);
			} else if (current().text == "Map") {
				advance();
				if (isRecoveryBoundary()) {
					var missingSpan = current().span;
					var missing = missingType("type arguments");
					return MapType(missing, ErrorType(missingSpan));
				}
				consume(TokenKind.Less);
				var key = parseType();
				var value = if (match(TokenKind.Comma))
					parseType();
				else if (isRecoveryBoundary() || check(TokenKind.Greater)) {
					recordExpected("comma");
					missingType("map value");
				} else {
					consume(TokenKind.Comma);
					parseType();
				};
				consume(TokenKind.Greater);
				return MapType(key, value);
			} else if (current().text == "Null") {
				advance();
				if (isRecoveryBoundary())
					return NullableType(missingType("type arguments"));
				consume(TokenKind.Less);
				var element = parseType();
				consume(TokenKind.Greater);
				return NullableType(element);
			}
		var name = parseQualifiedName();
		if (check(TokenKind.Less) && peekKind(1) == TokenKind.StringLiteral) {
			advance();
			var tag = consume(TokenKind.StringLiteral),
				value = decodeString(tag.text);
			consume(TokenKind.Greater);
			return NativeAbstractType(name, value);
		}
		if (match(TokenKind.Less)) {
			var arguments = [];
			if (!check(TokenKind.Greater) && !recoveringAtEnd()) {
				arguments.push(parseDelimitedType(TokenKind.Greater));
				while (match(TokenKind.Comma))
					if (!check(TokenKind.Greater) && !recoveringAtEnd())
						arguments.push(parseDelimitedType(TokenKind.Greater));
			}
			consume(TokenKind.Greater);
			return AppliedType(name, arguments);
		}
		return NamedType(name);
	}

	function failType(message:String):AstType {
		fail(current(), message);
		return null;
	}

	function parseStatementOrBlock():Array<AstStatement> {
		if (!match(TokenKind.LeftBrace)) {
			if (recovering && isRecoveryBoundary()) {
				recordExpected("statement or block");
				return [];
			}
			return parseStatements();
		}
		var statements = parseStatementBlockBody();
		consume(TokenKind.RightBrace);
		return statements;
	}

	/**
	 * Recover each statement inside a nested block independently. Catching only
	 * in the enclosing function makes synchronization skip the block's closing
	 * brace and any valid declarations that follow the malformed statement.
	 */
	function parseStatementBlockBody():Array<AstStatement> {
		var statements:Array<AstStatement> = [], bodyStart = position;
		while (!check(TokenKind.RightBrace) && !check(TokenKind.Eof)) {
			var statementStart = position;
			try {
				appendStatements(statements, parseStatements());
			}
			catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				statements.push(ErrorStatement(error.diagnostic.span));
				synchronizeStatement(bodyStart, statementStart);
			}
		}
		return statements;
	}

	function statementEnd(statements:Array<AstStatement>):SourceSpan
		return statements.length == 0 ? previous().span : statementSpan(statements[statements.length - 1]);

	inline function match(kind:TokenKind):Bool {
		if (tokens[position].kind != kind)
			return false;
		checkpoint();
		position++;
		return true;
	}

	function consume(kind:TokenKind):Token {
		var token = tokens[position];
		if (token.kind == kind) {
			checkpoint();
			position++;
			return token;
		}
		if (recovering && canInsert(kind))
			return insertMissing(kind);
		fail(token, 'Expected $kind, got ${token.kind}');
		return null;
	}

	function recoveringAtEnd():Bool
		return recovering && check(TokenKind.Eof);

	/** Whether the current token is a safe synchronization point for recovery. */
	function isRecoveryBoundary():Bool
		return recovering && (isExpressionTerminator(current().kind) || isDeclarationBoundary(current())
			|| current().kind == TokenKind.Else || current().kind == TokenKind.Catch
			|| current().kind == TokenKind.Case || current().kind == TokenKind.Default);

	function canInsert(kind:TokenKind):Bool
		return switch kind {
			case TokenKind.Semicolon: check(TokenKind.RightBrace) || check(TokenKind.Eof) || isTopLevelStart(current());
			case TokenKind.RightParen:
				check(TokenKind.LeftBrace)
				|| check(TokenKind.Colon)
				|| check(TokenKind.Semicolon)
				|| check(TokenKind.Arrow)
				|| check(TokenKind.Eof)
				|| isDeclarationBoundary(current());
			case TokenKind.RightBracket:
				check(TokenKind.Assign)
				|| check(TokenKind.Semicolon)
				|| check(TokenKind.Comma)
				|| check(TokenKind.RightParen)
				|| check(TokenKind.Eof);
			case TokenKind.Greater:
				check(TokenKind.Eof)
				|| check(TokenKind.LeftBrace)
				|| check(TokenKind.Semicolon)
				|| check(TokenKind.RightParen)
				|| check(TokenKind.RightBrace)
				|| isDeclarationBoundary(current());
			case TokenKind.Colon, TokenKind.LeftBrace:
				check(TokenKind.Eof);
			case TokenKind.RightBrace:
				check(TokenKind.Eof);
			default: false;
		};

	function insertMissing(kind:TokenKind):Token {
		var replacement = tokenText(kind),
			span = new SourceSpan(current().span.file, current().span.start, current().span.start);
		recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", 'Expected $kind, got ${current().kind}', span, compiler.Diagnostic.DiagnosticSeverity.Error,
			[
				{
					id: "insert-" + replacement,
					title: 'Insert "$replacement"',
					edits: [{span: span, replacement: replacement}]
				}
			]));
		return new Token(kind, replacement, span);
	}

	function missingFunctionBody():Void {
		var span = new SourceSpan(current().span.file, current().span.start, current().span.start);
		recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", "Expected function body", span, compiler.Diagnostic.DiagnosticSeverity.Error, [
			{id: "insert-function-body", title: "Insert function body", edits: [{span: span, replacement: " {}"}]}
		]));
	}

	function recordExpected(kind:String):Void {
		var span = new SourceSpan(current().span.file, current().span.start, current().span.start);
		recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", 'Expected $kind', span));
	}

	function recordRecoveryDiagnostic(diagnostic:compiler.Diagnostic):Void {
		diagnostic.origin = DiagnosticOrigin.ParserRecovery;
		if (recoveryDiagnostics.length < MAX_RECOVERY_DIAGNOSTICS)
			recoveryDiagnostics.push(diagnostic);
	}

	inline function checkpoint():Void {
		if (checkpointCallback != null)
			checkpointCallback();
	}

	static function tokenText(kind:TokenKind):String
		return switch kind {
			case TokenKind.Semicolon: ";";
			case TokenKind.RightParen: ")";
			case TokenKind.RightBracket: "]";
			case TokenKind.Colon: ":";
			case TokenKind.LeftBrace: "{";
			case TokenKind.RightBrace: "}";
			default: "";
		};

	function consumeName():Token {
		return if (isNameToken(current().kind)) advance(); else {
			fail(current(), 'Expected name, got ${current().kind}');
			null;
		};
	}

	function consumeDeclarationName(kind:String):String {
		return consumeDeclarationToken(kind).text;
	}

	function consumeDeclarationToken(kind:String):Token {
		if (isNameToken(current().kind))
			return advance();
		if (!recovering)
			return consume(TokenKind.Identifier);
		var span = new SourceSpan(current().span.file, current().span.start, current().span.start);
		recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", 'Expected Identifier, got ${current().kind}', span));
		return new Token(TokenKind.Identifier, "<missing>", new SourceSpan(current().span.file, current().span.start, current().span.start));
	}

	function missingType(kind:String):AstType {
		var span = new SourceSpan(current().span.file, current().span.start, current().span.start);
		recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", 'Expected $kind', span));
		return ErrorType(span);
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

	inline function check(kind:TokenKind):Bool
		return tokens[position].kind == kind;

	function advance():Token {
		checkpoint();
		return tokens[position++];
	}

	inline function current():Token
		return tokens[position];

	function peekKind(offset:Int):TokenKind
		return position + offset < tokens.length ? tokens[position + offset].kind : TokenKind.Eof;

	function previous():Token
		return tokens[position - 1];

	function fail(token:Token, message:String):Void
		throw new CompileError(new Diagnostic("E0002", message, token.span));

	function parseIntegerToken(token:Token, negative:Bool = false):Int {
		var hexadecimal = isHexIntegerToken(token),
			limit = hexadecimal ? Int64.parseString(negative ? "2147483648" : "4294967295") : Int64.parseString(negative ? "2147483648" : "2147483647"),
			magnitude = parseIntegerMagnitude(token);
		if (Int64.compare(magnitude, limit) > 0)
			fail(token,
				'Integer literal "${negative ? "-" : ""}${token.text}" is outside the ${hexadecimal && !negative ? "unsigned" : "signed"} 32-bit range');
		var signed = negative ? Int64.sub(Int64.ofInt(0), magnitude) : magnitude;
		if (hexadecimal && !negative && Int64.compare(signed, Int64.parseString("2147483647")) > 0)
			signed = Int64.sub(signed, Int64.parseString("4294967296"));
		return Int64.toInt(signed);
	}

	static function isHexIntegerToken(token:Token):Bool
		return StringTools.startsWith(token.text, "0x") || StringTools.startsWith(token.text, "0X");

	function parseIntegerMagnitude(token:Token):Int64 {
		if (isHexIntegerToken(token)) {
			var value = Int64.ofInt(0);
			for (index in 2...token.text.length) {
				if (Int64.compare(Int64.ushr(value, 60), Int64.ofInt(0)) != 0)
					fail(token, 'Integer literal "${token.text}" is outside the supported range');
				var code = token.text.charCodeAt(index),
					digit = code >= "0".code
						&& code <= "9".code ? code - "0".code : code >= "A".code
							&& code <= "F".code ? code - "A".code + 10 : code - "a".code + 10;
				value = Int64.or(Int64.shl(value, 4), Int64.ofInt(digit));
			}
			if (Int64.compare(value, Int64.ofInt(0)) < 0)
				fail(token, 'Integer literal "${token.text}" is outside the supported range');
			return value;
		}
		try {
			var value = Int64.parseString(token.text);
			if (Int64.compare(value, Int64.ofInt(0)) < 0)
				fail(token, 'Integer literal "${token.text}" is outside the supported range');
			return value;
		} catch (_:Dynamic) {
			throw new CompileError(new Diagnostic("E0002", 'Integer literal "${token.text}" is outside the supported range', token.span));
		}
	}

	static function expressionSpan(expression:AstExpression):SourceSpan
		return switch expression {
			case IntegerLiteral(_, span), FloatLiteral(_, span), StringLiteral(_, span), BoolLiteral(_, span), NullLiteral(span), Unreachable(span),
				EmptyExpression(span), ErrorExpression(span), Variable(_, span), Member(_, _, span), Add(_, _, span), Sub(_, _, span), Mul(_, _, span),
				Div(_, _, span), Mod(_, _, span), BitAnd(_, _, span), BitXor(_, _, span), BitOr(_, _, span), ShiftLeft(_, _, span), ShiftRight(_, _, span),
				UnsignedShiftRight(_, _, span), Negate(_, span), Less(_, _, span), LessEqual(_, _, span), Greater(_, _, span), GreaterEqual(_, _, span),
				Equal(_, _, span), NotEqual(_, _, span), Not(_, span), Call(_, _, span), ClosureCall(_, _, span), MethodCall(_, _, _, span), New(_, _, span),
				NewGeneric(_, _, _, span), NativeLayoutQuery(_, _, _, span), NewArray(_, _, span), NewMap(_, _, span), Index(_, _, span),
				PostfixIncrement(_, _, span), Lambda(_, _, span), And(_, _, span), Or(_, _, span), Conditional(_, _, _, span), BlockExpression(_, _, span),
				ThrowExpression(_, span), SwitchExpression(_, _, _, span), Cast(_, _, span): span;
			case ObjectLiteral(_, span), ArrayLiteral(_, span), MapLiteral(_, span), ArrayComprehension(_, _, _, _, _, span),
				MapComprehension(_, _, _, _, _, _, span), Range(_, _, span): span;
		}

	static function decodeString(text:String):String {
		var out = "", i = 1;
		while (i < text.length - 1) {
			var c = text.charAt(i++);
			if (c != "\\") {
				out += c;
				continue;
			}
			var escaped = text.charAt(i++);
			out += switch escaped {
				case "n": "\n";
				case "r": "\r";
				case "t": "\t";
				case "\"": "\"";
				case "\\": "\\";
				default: escaped;
			};
		}
		return out;
	}

	static function parseStringExpression(token:Token):AstExpression {
		var text = token.text;
		if (text.charAt(0) != "'" || text.indexOf("$") < 0)
			return StringLiteral(decodeString(text), token.span);
		var parts:Array<AstExpression> = [], literal = "", index = 1, end = text.length - 1;
		while (index < end) {
			var character = text.charAt(index);
			if (character == "\\") {
				literal += decodeEscape(text.charAt(index + 1));
				index += 2;
				continue;
			}
			if (character != "$") {
				literal += character;
				index++;
				continue;
			}
			if (index + 1 < end && text.charAt(index + 1) == "$") {
				literal += "$";
				index += 2;
				continue;
			}
			if (index + 1 >= end || text.charAt(index + 1) != "{" && !isInterpolationIdentifierStart(text.charCodeAt(index + 1))) {
				literal += "$";
				index++;
				continue;
			}
			appendStringLiteral(parts, literal, token.span);
			literal = "";
			var expressionStart = index + 1, expressionEnd = expressionStart;
			if (expressionStart < end && text.charAt(expressionStart) == "{") {
				expressionStart++;
				expressionEnd = interpolationEnd(text, expressionStart, end, token.span);
				index = expressionEnd + 1;
			} else {
				while (expressionEnd < end && isInterpolationIdentifierPart(text.charCodeAt(expressionEnd)))
					expressionEnd++;
				index = expressionEnd;
			}
			var expression = parseInterpolatedExpression(text.substring(expressionStart, expressionEnd), token.span,
				haxe.io.Bytes.ofString(text.substring(0, expressionStart)).length);
			parts.push(Call("Std.string", [expression], expressionSpan(expression)));
		}
		appendStringLiteral(parts, literal, token.span);
		var result = parts[0];
		for (partIndex in 1...parts.length)
			result = Add(result, parts[partIndex], expressionSpan(result).merge(expressionSpan(parts[partIndex])));
		return result;
	}

	static function appendStringLiteral(parts:Array<AstExpression>, value:String, span:SourceSpan):Void {
		if (value.length > 0 || parts.length == 0)
			parts.push(StringLiteral(value, span));
	}

	static function decodeEscape(escaped:String):String
		return switch escaped {
			case "n": "\n";
			case "r": "\r";
			case "t": "\t";
			case "\"": "\"";
			case "'": "'";
			case "\\": "\\";
			default: escaped;
		};

	static function interpolationEnd(text:String, start:Int, end:Int, span:SourceSpan):Int {
		var depth = 1, index = start, quote = "";
		while (index < end) {
			var character = text.charAt(index);
			if (quote != "") {
				if (character == "\\")
					index++;
				else if (character == quote)
					quote = "";
			} else if (character == "\"" || character == "'")
				quote = character;
			else if (character == "{")
				depth++;
			else if (character == "}") {
				depth--;
				if (depth == 0)
					return index;
			}
			index++;
		}
		throw new CompileError(new Diagnostic("E0002", "Unterminated string interpolation", span));
	}

	static function parseInterpolatedExpression(source:String, outer:SourceSpan, offset:Int):AstExpression {
		var interpolationFile = new compiler.Source.SourceFile(outer.file.path, source),
			shifted:Array<Token> = [];
		for (token in new Lexer(interpolationFile).tokenize())
			shifted.push(new Token(token.kind, token.text,
				new SourceSpan(outer.file, outer.start + offset + token.span.start, outer.start + offset + token.span.end)));
		var parser = new Parser(shifted),
			expression = parser.parseExpression();
		parser.consume(TokenKind.Eof);
		return expression;
	}

	static function isInterpolationIdentifierPart(code:Int):Bool
		return isInterpolationIdentifierStart(code) || code >= 48 && code <= 57;

	static function isInterpolationIdentifierStart(code:Int):Bool
		return code >= 65 && code <= 90 || code >= 97 && code <= 122 || code == 95;

	static function statementSpan(statement:AstStatement):SourceSpan
		return switch statement {
			case ErrorStatement(span): span;
			case UninitializedDeclaration(_, _, span), VarDeclaration(_, _, _, span), Assignment(_, _, span), IndexAssignment(_, _, _, span),
				FieldAssignment(_, _, _, span), Return(_, span), ReturnVoid(span), Throw(_, span), Try(_, _, span), If(_, _, _, span), While(_, _, span),
				DoWhile(_, _,
					span), ForIn(_, _, _, _, span), Break(span), Continue(span), Switch(_, _, _, _, span), Increment(_, _, span), Expression(_, span): span;
		}
}
