package compiler.syntax;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstFieldAccess;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstField;
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
import compiler.syntax.SyntaxTree.ParserMode;
import compiler.syntax.SyntaxTree.SyntaxTree;
import compiler.syntax.SyntaxTree.SyntaxKind;
import compiler.syntax.SyntaxTree.SyntaxNodePayload;
import compiler.syntax.SyntaxTree.SyntaxFunctionParameter;
import compiler.syntax.SyntaxScanner.LosslessToken;
import compiler.syntax.AstLowerer;
import compiler.Diagnostic.CompileError;
import haxe.Int64;
import compiler.Diagnostic.DiagnosticOrigin;

typedef RecoveredParse = {
	final program:AstProgram;
	final diagnostics:Array<compiler.Diagnostic>;
}

typedef ParsedType = {
	final ast:AstType;
	final payload:compiler.syntax.SyntaxTree.SyntaxTypePayload;
}

/** Recursive-descent parser for the supported Haxe-compatible source subset. */
class Parser {
	static inline final MAX_RECOVERY_DIAGNOSTICS = 20;

	final tokens:Array<Token>;
	final checkpointCallback:Null<Void->Void>;
	public var cst(get, never):Null<SyntaxTree>;
	final cstRecorder:Null<ParserCstRecorder>;
	var parserPayloads:Map<Int, SyntaxNodePayload> = [];
	var parserExpressionPayloads:Map<String, compiler.syntax.SyntaxTree.SyntaxExpressionPayload> = [];
	var lastTypeArgumentPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload> = [];
	var position:Int = 0;
	var recovering:Bool = false;
	var recoveryDiagnostics:Array<compiler.Diagnostic> = [];

	public function new(tokens:Array<Token>, ?checkpoint:Void->Void, ?mode:ParserMode, ?losslessTokens:Array<LosslessToken>) {
		this.tokens = tokens;
		this.checkpointCallback = checkpoint;
		this.cstRecorder = mode == null ? null : switch mode {
			case ParserMode.AstOnly: null;
			case ParserMode.Cst(source): new ParserCstRecorder(source, losslessTokens);
		};
	}

	function get_cst():Null<SyntaxTree>
		return cstRecorder == null ? null : cstRecorder.tree;

	inline function recordCstNode(kind:SyntaxKind, span:SourceSpan, ?payload:SyntaxNodePayload):Void {
		if (cstRecorder != null)
			cstRecorder.node(kind, span, payload);
	}

	inline function recordStatementCst(kind:SyntaxKind, statement:AstStatement, span:SourceSpan):Void {
		var payload = parserStatementPayload(statement);
		if (payload != null)
			recordCstNode(kind, span, SyntaxNodePayload.Statement(payload));
	}

	public function parseProgram():AstProgram {
		var packageName:Null<String> = null, imports = [], importAliases:Map<String, String> = [];
		if (match(TokenKind.Package)) {
			var packageStart = previous().span;
			packageName = parseQualifiedName();
			var packageEnd = consume(TokenKind.Semicolon).span;
			recordCstNode(SyntaxKind.PackageDeclaration, packageStart.merge(packageEnd), SyntaxNodePayload.PackageName(packageName));
		}
		while (match(TokenKind.Import)) {
			var importStart = previous().span;
			var path = parseQualifiedName(true), aliasName:Null<String> = null;
			if (recovering && check(TokenKind.Dot)) {
				advance();
				recordExpected("import name");
			}
			imports.push(path);
			if (check(TokenKind.Identifier) && current().text == "as") {
				advance();
				var alias = consumeDeclarationToken("import alias");
				if (alias.text != "<missing>") {
					aliasName = alias.text;
					if (importAliases.exists(alias.text))
						fail(alias, 'Duplicate import alias "${alias.text}"');
					importAliases.set(alias.text, path);
				}
			}
			var importEnd = consume(TokenKind.Semicolon).span;
			recordCstNode(SyntaxKind.ImportDeclaration, importStart.merge(importEnd), SyntaxNodePayload.Import(path, aliasName));
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
				if (match(TokenKind.Typedef)) {
					var alias = parseTypeAlias(visibility == null ? previous().span : visibility.span,
						visibility != null && visibility.kind == TokenKind.Private);
					aliases.push(alias);
					recordCstNode(SyntaxKind.TypeAliasDeclaration, alias.span, parserPayloads.get(alias.span.start));
				}
				else if (match(TokenKind.Enum)) {
					var start = previous().span;
					if (check(TokenKind.Identifier) && current().text == "abstract") {
						advance();
						var enumAbstract = parseEnumAbstract(start);
						enumAbstracts.push(enumAbstract);
						recordCstNode(SyntaxKind.EnumAbstractDeclaration, enumAbstract.span,
							parserPayloads.get(enumAbstract.span.start) == null ? enumAbstractHeader(enumAbstract) : parserPayloads.get(enumAbstract.span.start));
					} else {
						var enumeration = parseEnum(start, metadata);
						enums.push(enumeration);
						recordCstNode(SyntaxKind.EnumDeclaration, enumeration.span,
							parserPayloads.get(enumeration.span.start) == null ? enumHeader(enumeration) : parserPayloads.get(enumeration.span.start));
					}
				} else if (check(TokenKind.Interface)) {
					var interfaceDeclaration = parseInterface();
					interfaces.push(interfaceDeclaration);
					recordCstNode(SyntaxKind.InterfaceDeclaration, interfaceDeclaration.span,
						parserPayloads.get(interfaceDeclaration.span.start) == null ? interfaceHeader(interfaceDeclaration) : parserPayloads.get(interfaceDeclaration.span.start));
					for (method in interfaceDeclaration.methods)
						recordCstNode(SyntaxKind.FunctionDeclaration, method.span,
							parserPayloads.get(method.span.start) == null ? functionHeader(method) : parserPayloads.get(method.span.start));
				} else if (check(TokenKind.Class)) {
					var classDeclaration = parseClass(visibility != null && visibility.kind == TokenKind.Private, metadata, externDeclaration);
					classes.push(classDeclaration);
					recordCstNode(SyntaxKind.ClassDeclaration, classDeclaration.span,
						parserPayloads.get(classDeclaration.span.start) == null ? classHeader(classDeclaration) : parserPayloads.get(classDeclaration.span.start));
					for (field in classDeclaration.fields)
						recordCstNode(SyntaxKind.FieldDeclaration, field.span,
							parserPayloads.get(field.span.start) == null ? fieldHeader(field) : parserPayloads.get(field.span.start));
					for (method in classDeclaration.methods)
						recordCstNode(SyntaxKind.FunctionDeclaration, method.span,
							parserPayloads.get(method.span.start) == null ? functionHeader(method) : parserPayloads.get(method.span.start));
				}
				else if (visibility != null)
					fail(current(), "Top-level visibility modifier is not supported for this declaration");
				else if (check(TokenKind.Identifier) && current().text == "abstract") {
					var start = advance().span;
					var abstractDeclaration = parseAbstract(start, externDeclaration, metadata);
					abstracts.push(abstractDeclaration);
					recordCstNode(SyntaxKind.AbstractDeclaration, abstractDeclaration.span,
						parserPayloads.get(abstractDeclaration.span.start) == null ? abstractHeader(abstractDeclaration) : parserPayloads.get(abstractDeclaration.span.start));
					for (method in abstractDeclaration.methods)
						recordCstNode(SyntaxKind.FunctionDeclaration, method.span,
							parserPayloads.get(method.span.start) == null ? functionHeader(method) : parserPayloads.get(method.span.start));
				} else {
					var functionDeclaration = parseFunction(false, externDeclaration, metadata);
					functions.push(functionDeclaration);
					recordCstNode(SyntaxKind.FunctionDeclaration, functionDeclaration.span,
						parserPayloads.get(functionDeclaration.span.start) == null ? functionHeader(functionDeclaration) : parserPayloads.get(functionDeclaration.span.start));
				}
			} catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				synchronizeTopLevel(declarationStart);
			}
		}
		var program:AstProgram = {
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
		if (cstRecorder != null) {
			cstRecorder.finish();
			program = AstLowerer.lower(cstRecorder.tree, program, !recovering);
		}
		return program;
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
			typeConstraintPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypeConstraintPayload> = [],
			typeParameters = parseTypeParameters(typeConstraints, typeConstraintPayloads);
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
		var parsedUnderlying = parseTypeResult(), underlying = parsedUnderlying.ast,
			underlyingPayload = parsedUnderlying.payload;
		consume(TokenKind.RightParen);
		var fromTypes = [], toTypes = [], fromPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload> = [],
			toPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload> = [];
		while (!check(TokenKind.LeftBrace) && !recoveringAtEnd()) {
			var conversion = consume(TokenKind.Identifier);
			if (conversion.text != "from" && conversion.text != "to")
				fail(conversion, 'Expected "from" or "to"');
			var parsedConversion = parseTypeResult(), conversionType = parsedConversion.ast;
			if (conversion.text == "from")
				{fromTypes.push(conversionType); fromPayloads.push(parsedConversion.payload);}
			else
				{toTypes.push(conversionType); toPayloads.push(parsedConversion.payload);}
		}
		if (recovering && isDeclarationBoundary(current())) {
			recordExpected("abstract body");
			var recoveredAbstract:AstAbstract = {
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
			parserPayloads.set(recoveredAbstract.span.start, SyntaxNodePayload.AbstractHeader(name, isExtern, typeParameters,
				typeConstraintPayloads, underlyingPayload, fromPayloads, toPayloads));
			return recoveredAbstract;
		}
		var enumBodyStart = consume(TokenKind.LeftBrace).span;
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
		recordCstNode(SyntaxKind.Block, enumBodyStart.merge(end));
		var abstractDeclaration:AstAbstract = {
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
		parserPayloads.set(abstractDeclaration.span.start, SyntaxNodePayload.AbstractHeader(name, isExtern, typeParameters,
			typeConstraintPayloads, underlyingPayload, fromPayloads, toPayloads));
		return abstractDeclaration;
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
		var parsedUnderlying = parseTypeResult(), underlying = parsedUnderlying.ast,
			underlyingPayload = parsedUnderlying.payload;
		consume(TokenKind.RightParen);
		var fromTypes = [], toTypes = [], fromPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload> = [],
			toPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload> = [],
			valuePayloads:Array<compiler.syntax.SyntaxTree.SyntaxEnumValuePayload> = [];
		while (!check(TokenKind.LeftBrace) && !recoveringAtEnd()) {
			var conversion = consume(TokenKind.Identifier);
			if (conversion.text != "from" && conversion.text != "to")
				fail(conversion, 'Expected "from" or "to"');
			var parsedConversion = parseTypeResult(), conversionType = parsedConversion.ast;
			if (conversion.text == "from")
				{fromTypes.push(conversionType); fromPayloads.push(parsedConversion.payload);}
			else
				{toTypes.push(conversionType); toPayloads.push(parsedConversion.payload);}
		}
		if (recovering && isDeclarationBoundary(current())) {
			recordExpected("enum abstract body");
			var recoveredEnumAbstract:AstEnumAbstract = {
				name: name,
				underlying: underlying,
				fromTypes: fromTypes,
				toTypes: toTypes,
				values: [],
				span: start.merge(previous().span)
			};
			parserPayloads.set(recoveredEnumAbstract.span.start, SyntaxNodePayload.EnumAbstractHeader(name, underlyingPayload,
				fromPayloads, toPayloads, valuePayloads));
			return recoveredEnumAbstract;
		}
		var abstractBodyStart = consume(TokenKind.LeftBrace).span;
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
				var valuePayload = expressionPayload(value);
				if (valuePayload != null)
					valuePayloads.push({name: valueName.text, value: valuePayload});
			} catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				synchronizeEnumAbstractValue(bodyStart, valueStart);
			}
		}
		var end = consume(TokenKind.RightBrace).span;
		recordCstNode(SyntaxKind.Block, abstractBodyStart.merge(end));
		var enumAbstract:AstEnumAbstract = {
			name: name,
			underlying: underlying,
			fromTypes: fromTypes,
			toTypes: toTypes,
			values: values,
			span: start.merge(end)
		};
		if (valuePayloads.length == values.length)
			parserPayloads.set(enumAbstract.span.start, SyntaxNodePayload.EnumAbstractHeader(name, underlyingPayload,
				fromPayloads, toPayloads, valuePayloads));
		return enumAbstract;
	}

	function parseTypeAlias(start:SourceSpan, isPrivate:Bool):AstTypeAlias {
		var name = consumeDeclarationName("typedef"),
			typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeConstraintPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypeConstraintPayload> = [],
			typeParameters = parseTypeParameters(typeConstraints, typeConstraintPayloads);
		consume(TokenKind.Assign);
		var parsedType = parseTypeResult(), type = parsedType.ast, end = previous().span;
		switch type {
			case AnonymousType(_):
				if (match(TokenKind.Semicolon))
					end = previous().span;
			default:
				end = consume(TokenKind.Semicolon).span;
		}
		var alias:AstTypeAlias = {
			name: name,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			type: type,
			isPrivate: isPrivate,
			span: start.merge(end)
		};
		parserPayloads.set(alias.span.start, SyntaxNodePayload.TypeAliasHeader(name, isPrivate, typeParameters,
			typeConstraintPayloads, parsedType.payload));
		return alias;
	}

	function parseEnum(start:SourceSpan, metadata:Array<compiler.syntax.Ast.AstMetadata>):AstEnum {
		var name = consumeDeclarationName("enum"), typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeConstraintPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypeConstraintPayload> = [],
			typeParameters = parseTypeParameters(typeConstraints, typeConstraintPayloads), cases = [],
			casePayloads:Array<compiler.syntax.SyntaxTree.SyntaxEnumCasePayload> = [];
		if (recovering && isDeclarationBoundary(current())) {
			recordExpected("enum body");
			var recoveredEnum:AstEnum = {
				name: name,
				typeParameters: typeParameters,
				typeConstraints: typeConstraints,
				cases: cases,
				span: start.merge(previous().span)
			};
			parserPayloads.set(recoveredEnum.span.start, SyntaxNodePayload.EnumHeader(name, typeParameters,
				typeConstraintPayloads, casePayloads));
			return recoveredEnum;
		}
		var enumAbstractBodyStart = consume(TokenKind.LeftBrace).span;
		var bodyStart = position;
		while (!check(TokenKind.RightBrace) && !recoveringAtEnd()) {
			var caseStart = position;
			try {
				var caseMetadata = parseMetadata(),
					caseToken = consumeName(),
					params:Array<compiler.syntax.Ast.AstEnumParameter> = [];
				var payloadParameters:Array<compiler.syntax.SyntaxTree.SyntaxEnumParameterPayload> = [];
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
							var parsedType = parseTypeResult(), type = parsedType.ast;
							params.push({
								name: name,
								type: type,
								optional: optional,
								span: parameterStart.merge(previous().span)
							});
							payloadParameters.push({name: name, type: parsedType.payload, optional: optional});
						} while (match(TokenKind.Comma));
					consume(TokenKind.RightParen);
				}
				cases.push({
					name: caseToken.text,
					metadata: caseMetadata,
					params: params,
					span: caseToken.span.merge(previous().span)
				});
				casePayloads.push({name: caseToken.text, parameters: payloadParameters});
				consume(TokenKind.Semicolon);
			} catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				synchronizeEnumCase(bodyStart, caseStart);
			}
		}
		var end = consume(TokenKind.RightBrace).span;
		recordCstNode(SyntaxKind.Block, enumAbstractBodyStart.merge(end));
		var enumeration:AstEnum = {
			name: name,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			metadata: metadata,
			cases: cases,
			span: start.merge(end)
		};
		parserPayloads.set(enumeration.span.start, SyntaxNodePayload.EnumHeader(name, typeParameters,
			typeConstraintPayloads, casePayloads));
		return enumeration;
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
			typeConstraintPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypeConstraintPayload> = [],
			typeParameters = parseTypeParameters(typeConstraints, typeConstraintPayloads);
		var arguments = [], parameterPayloads:Array<compiler.syntax.SyntaxTree.SyntaxArgumentPayload> = [], payloadComplete = true;
		var parameterStart:Null<SourceSpan> = null;
		if (recovering && (recoveringAtEnd() || isDeclarationBoundary(current())))
			recordExpected("left parenthesis");
		else {
			parameterStart = consume(TokenKind.LeftParen).span;
			while (!check(TokenKind.RightParen) && !recoveringAtEnd() && !canInsert(TokenKind.RightParen)) {
				if (check(TokenKind.Comma)) {
					recordExpected("parameter");
					advance();
					continue;
				}
				var optional = match(TokenKind.Question),
					argumentToken = consumeDeclarationToken("parameter");
				var parsedArgumentType = match(TokenKind.Colon) ? parseTypeResult() : parsedType(InferredType,
					compiler.syntax.SyntaxTree.SyntaxTypePayload.InferredType),
					argumentType = parsedArgumentType.ast,
					defaultValue = match(TokenKind.Assign) ? parseExpression() : null;
				arguments.push({
					name: argumentToken.text,
					type: argumentType,
					span: argumentToken.span.merge(previous().span),
					optional: optional || defaultValue != null,
					defaultValue: defaultValue
				});
				var defaultPayload = defaultValue == null ? null : expressionPayload(defaultValue);
				if (defaultValue != null && defaultPayload == null)
					payloadComplete = false;
				parameterPayloads.push({name: argumentToken.text, type: parsedArgumentType.payload,
					optional: optional || defaultValue != null, defaultValue: defaultPayload});
				if (!match(TokenKind.Comma))
					break;
			}
			var parameterEnd = consume(TokenKind.RightParen).span;
			if (parameterStart != null)
				recordCstNode(SyntaxKind.ParameterList, parameterStart.merge(parameterEnd));
		}
		var parsedResult = if (match(TokenKind.Colon))
			parseTypeResult();
		else if (allowMissingReturn && name == "new")
			parsedType(VoidType, compiler.syntax.SyntaxTree.SyntaxTypePayload.VoidType);
		else
			parsedType(InferredType, compiler.syntax.SyntaxTree.SyntaxTypePayload.InferredType);
		var result = parsedResult.ast;
		var statements = [], end:SourceSpan;
		if (isExtern) {
			end = consume(TokenKind.Semicolon).span;
		} else if (match(TokenKind.LeftBrace)) {
			var blockStart = previous().span;
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
			recordCstNode(SyntaxKind.Block, blockStart.merge(end));
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
		var functionDeclaration:AstFunction = {
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
		if (payloadComplete)
			{
				var payload = SyntaxNodePayload.FunctionHeaderRich(name, isStatic, isExtern,
					typeParameters, typeConstraintPayloads, parameterPayloads, parsedResult.payload);
				parserPayloads.set(start.start, payload);
				parserPayloads.set(functionDeclaration.span.start, payload);
			}
		return functionDeclaration;
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
		return parseDelimitedTypeResult(endKind).ast;
	}

	function parseDelimitedTypeResult(endKind:TokenKind):ParsedType {
		try {
			var type = parseTypeResult();
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
			return {ast: ErrorType(error.diagnostic.span), payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType};
		}
	}

	function synchronizeTypeArgument():Void {
		var angleDepth = 0, braceDepth = 0, bracketDepth = 0, parenDepth = 0;
		while (!check(TokenKind.Eof)) {
			if (angleDepth == 0 && braceDepth == 0 && bracketDepth == 0 && parenDepth == 0
				&& (check(TokenKind.Comma) || check(TokenKind.Greater) || check(TokenKind.Semicolon)
					|| check(TokenKind.RightParen) || check(TokenKind.RightBrace) || check(TokenKind.LeftBrace)
					|| check(TokenKind.Extends) || check(TokenKind.Implements)
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

	function parseTypeParameters(?constraints:Array<compiler.syntax.Ast.AstTypeConstraint>,
			?constraintPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypeConstraintPayload>):Array<String> {
		var result = [];
		if (!match(TokenKind.Less))
			return result;
		var typeParameterStart = previous().span;
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
					var parsedConstraint = parseDelimitedTypeResult(grouped ? TokenKind.RightParen : TokenKind.Greater),
						constraint = parsedConstraint.ast;
					if (constraints != null)
						constraints.push({parameter: parameter.text, type: constraint, span: parameter.span.merge(previous().span)});
					if (constraintPayloads != null)
						constraintPayloads.push({parameter: parameter.text, type: parsedConstraint.payload});
				} while (grouped && match(TokenKind.Comma));
				if (grouped)
					consume(TokenKind.RightParen);
			}
			if (!match(TokenKind.Comma))
				break;
		}
		var typeParameterEnd = consume(TokenKind.Greater).span;
		recordCstNode(SyntaxKind.TypeParameterList, typeParameterStart.merge(typeParameterEnd));
		return result;
	}

	function parseTypeArguments():Array<AstType> {
		var result:Array<AstType> = [], payloads:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload> = [];
		lastTypeArgumentPayloads = [];
		if (!match(TokenKind.Less))
			return result;
		var typeArgumentStart = previous().span;
		if (recovering && (isExpressionTerminator(current().kind) || isDeclarationBoundary(current()))) {
			result.push(missingType("type argument"));
			payloads.push(compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType);
		}
		else {
			while (!check(TokenKind.Greater) && !recoveringAtEnd()) {
				var parsed = parseDelimitedTypeResult(TokenKind.Greater);
				result.push(parsed.ast);
				payloads.push(parsed.payload);
				if (!match(TokenKind.Comma) || check(TokenKind.Greater))
					break;
			}
		}
		var typeArgumentEnd = consume(TokenKind.Greater).span;
		recordCstNode(SyntaxKind.TypeArgumentList, typeArgumentStart.merge(typeArgumentEnd));
		lastTypeArgumentPayloads = payloads;
		return result;
	}

	function parseClass(isPrivate:Bool, metadata:Array<compiler.syntax.Ast.AstMetadata>, isExtern:Bool = false):AstClass {
		var start = consume(TokenKind.Class).span,
			name = consumeDeclarationName("class"),
			typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeConstraintPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypeConstraintPayload> = [],
			typeParameters = parseTypeParameters(typeConstraints, typeConstraintPayloads),
			base:Null<AstType> = null,
			basePayload:Null<compiler.syntax.SyntaxTree.SyntaxTypePayload> = null,
			interfaces = [], interfacePayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload> = [];
		if (match(TokenKind.Extends)) {
			var parsedBase = recovering && (check(TokenKind.LeftBrace) || isDeclarationBoundary(current()))
				? parsedType(missingType("base type"), compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType)
				: parseDelimitedTypeResult(TokenKind.LeftBrace);
			base = parsedBase.ast;
			basePayload = parsedBase.payload;
		}
		while (match(TokenKind.Implements)) {
			var parsedInterface = recovering && (check(TokenKind.LeftBrace) || isDeclarationBoundary(current()))
				? parsedType(missingType("implemented type"), compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType)
				: parseDelimitedTypeResult(TokenKind.LeftBrace);
			interfaces.push(parsedInterface.ast);
			interfacePayloads.push(parsedInterface.payload);
			while (match(TokenKind.Comma)) {
				var nextInterface = recovering && (check(TokenKind.LeftBrace) || isDeclarationBoundary(current()))
					? parsedType(missingType("implemented type"), compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType)
					: parseDelimitedTypeResult(TokenKind.LeftBrace);
				interfaces.push(nextInterface.ast);
				interfacePayloads.push(nextInterface.payload);
			}
		}
		if (recovering && isDeclarationBoundary(current())) {
			recordExpected("class body");
			var recoveredClass:AstClass = {
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
			parserPayloads.set(recoveredClass.span.start, SyntaxNodePayload.ClassHeaderRich(name, isPrivate, isExtern,
				typeParameters, typeConstraintPayloads, basePayload, interfacePayloads));
			return recoveredClass;
		}
		var classBodyStart = consume(TokenKind.LeftBrace).span;
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
					var parsedFieldType:Null<ParsedType> = match(TokenKind.Colon) ? parseTypeResult() : null,
						fieldType = parsedFieldType == null ? null : parsedFieldType.ast,
						initializer = match(TokenKind.Assign) ? parseExpression() : null,
						initializerPayload = initializer == null ? null : expressionPayload(initializer);
					if (fieldType == null) {
						if (initializer == null)
							fail(current(), 'Field "$fieldName" requires a type or initializer');
					}
					var end = consume(TokenKind.Semicolon).span;
					var field:AstField = {
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
					};
					fields.push(field);
					if (initializer == null || initializerPayload != null)
						parserPayloads.set(field.span.start, SyntaxNodePayload.FieldHeaderRich(fieldName,
							parsedFieldType == null ? null : parsedFieldType.payload, initializerPayload, isStatic, isInline, isFinal,
							fieldAccessName(readAccess), fieldAccessName(writeAccess)));
				}
			} catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				synchronizeClassMember(bodyStart, memberStart);
			}
		}
		var end = consume(TokenKind.RightBrace).span;
		recordCstNode(SyntaxKind.Block, classBodyStart.merge(end));
		var classDeclaration:AstClass = {
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
		parserPayloads.set(classDeclaration.span.start, SyntaxNodePayload.ClassHeaderRich(name, isPrivate, isExtern,
			typeParameters, typeConstraintPayloads, basePayload, interfacePayloads));
		return classDeclaration;
	}

	static function simpleTypeName(type:Null<AstType>):Null<String> {
		return type == null ? null : switch type {
			case IntType: "Int";
			case BoolType: "Bool";
			case FloatType: "Float";
			case StringType: "String";
			case VoidType: "Void";
			case InferredType: "?";
			case NamedType(name): name;
			default: null;
		};
	}

	static function classHeader(classDeclaration:AstClass):SyntaxNodePayload {
		var baseType = classDeclaration.base == null ? null : simpleTypePayload(classDeclaration.base), interfaceTypes = [],
			typeConstraints = simpleTypeConstraintPayloads(classDeclaration.typeConstraints);
		for (interfaceType in classDeclaration.interfaces) {
			var payload = simpleTypePayload(interfaceType);
			if (payload == null)
				return SyntaxNodePayload.ClassHeader(classDeclaration.name, classDeclaration.isPrivate, classDeclaration.isExtern == true,
					classDeclaration.typeParameters, simpleTypeName(classDeclaration.base), [for (type in classDeclaration.interfaces) simpleTypeName(type)]);
			interfaceTypes.push(payload);
		}
		if (typeConstraints == null)
			return SyntaxNodePayload.ClassHeader(classDeclaration.name, classDeclaration.isPrivate, classDeclaration.isExtern == true,
				classDeclaration.typeParameters, simpleTypeName(classDeclaration.base), [for (type in classDeclaration.interfaces) simpleTypeName(type)]);
		return SyntaxNodePayload.ClassHeaderRich(classDeclaration.name, classDeclaration.isPrivate, classDeclaration.isExtern == true,
			classDeclaration.typeParameters, typeConstraints, baseType, interfaceTypes);
	}

	static function typeAliasHeader(alias:AstTypeAlias):Null<SyntaxNodePayload> {
		var type = simpleTypePayload(alias.type), typeConstraints = simpleTypeConstraintPayloads(alias.typeConstraints);
		return type == null || typeConstraints == null ? null
			: SyntaxNodePayload.TypeAliasHeader(alias.name, alias.isPrivate, alias.typeParameters, typeConstraints, type);
	}

	static function enumHeader(enumeration:AstEnum):Null<SyntaxNodePayload> {
		var cases:Array<compiler.syntax.SyntaxTree.SyntaxEnumCasePayload> = [],
			typeConstraints = simpleTypeConstraintPayloads(enumeration.typeConstraints);
		if (typeConstraints == null)
			return null;
		for (caseDeclaration in enumeration.cases) {
			var parameters:Array<compiler.syntax.SyntaxTree.SyntaxEnumParameterPayload> = [];
			for (parameter in caseDeclaration.params) {
				var type = simpleTypePayload(parameter.type);
				if (type == null)
					return null;
				parameters.push({name: parameter.name, type: type, optional: parameter.optional});
			}
			cases.push({name: caseDeclaration.name, parameters: parameters});
		}
		return SyntaxNodePayload.EnumHeader(enumeration.name, enumeration.typeParameters, typeConstraints, cases);
	}

	static function enumAbstractHeader(declaration:AstEnumAbstract):Null<SyntaxNodePayload> {
		var underlying = simpleTypePayload(declaration.underlying), fromTypes = simpleTypePayloads(declaration.fromTypes), toTypes = simpleTypePayloads(declaration.toTypes), values:Array<compiler.syntax.SyntaxTree.SyntaxEnumValuePayload> = [];
		if (underlying == null || fromTypes == null || toTypes == null)
			return null;
		for (value in declaration.values) {
			var payload = simpleExpressionPayload(value.value);
			if (payload == null)
				return null;
			values.push({name: value.name, value: payload});
		}
		return SyntaxNodePayload.EnumAbstractHeader(declaration.name, underlying, fromTypes, toTypes, values);
	}

	static function abstractHeader(declaration:AstAbstract):Null<SyntaxNodePayload> {
		var underlying = simpleTypePayload(declaration.underlying), fromTypes = simpleTypePayloads(declaration.fromTypes), toTypes = simpleTypePayloads(declaration.toTypes),
			typeConstraints = simpleTypeConstraintPayloads(declaration.typeConstraints);
		return underlying == null || fromTypes == null || toTypes == null || typeConstraints == null ? null
			: SyntaxNodePayload.AbstractHeader(declaration.name, declaration.isExtern == true, declaration.typeParameters,
				typeConstraints, underlying, fromTypes, toTypes);
	}

	static function interfaceHeader(declaration:AstInterface):Null<SyntaxNodePayload> {
		var bases = simpleTypePayloads(declaration.bases), typeConstraints = simpleTypeConstraintPayloads(declaration.typeConstraints);
		return bases == null || typeConstraints == null ? null
			: SyntaxNodePayload.InterfaceHeader(declaration.name, declaration.typeParameters, typeConstraints, bases);
	}

	static function fieldHeader(field:AstField):SyntaxNodePayload {
		var type = field.type == null ? null : simpleTypePayload(field.type), initializer = field.initializer == null ? null : simpleExpressionPayload(field.initializer);
		if (field.type != null && type == null || field.initializer != null && initializer == null)
			return SyntaxNodePayload.FieldHeader(field.name, simpleTypeName(field.type), field.isStatic, field.isInline, field.isFinal,
				fieldAccessName(field.readAccess), fieldAccessName(field.writeAccess));
		return SyntaxNodePayload.FieldHeaderRich(field.name, type, initializer, field.isStatic, field.isInline, field.isFinal,
			fieldAccessName(field.readAccess), fieldAccessName(field.writeAccess));
	}

	static function functionHeader(functionDeclaration:AstFunction):SyntaxNodePayload {
		var parameters = simpleArgumentPayloads(functionDeclaration.arguments), resultType = simpleTypePayload(functionDeclaration.result);
		if (parameters == null || resultType == null) {
			var simpleParameters:Array<SyntaxFunctionParameter> = [];
			for (argument in functionDeclaration.arguments)
				simpleParameters.push({name: argument.name, typeName: simpleTypeName(argument.type), optional: argument.optional == true});
			return SyntaxNodePayload.FunctionHeader(functionDeclaration.name, functionDeclaration.isStatic,
				functionDeclaration.isExtern == true, functionDeclaration.typeParameters == null ? [] : functionDeclaration.typeParameters,
				simpleParameters, simpleTypeName(functionDeclaration.result));
		}
		var typeConstraints = simpleTypeConstraintPayloads(functionDeclaration.typeConstraints);
		return typeConstraints == null ? SyntaxNodePayload.FunctionHeader(functionDeclaration.name, functionDeclaration.isStatic,
			functionDeclaration.isExtern == true, functionDeclaration.typeParameters == null ? [] : functionDeclaration.typeParameters,
			[for (argument in functionDeclaration.arguments) {name: argument.name, typeName: simpleTypeName(argument.type), optional: argument.optional == true}],
			simpleTypeName(functionDeclaration.result)) : SyntaxNodePayload.FunctionHeaderRich(functionDeclaration.name, functionDeclaration.isStatic,
			functionDeclaration.isExtern == true, functionDeclaration.typeParameters == null ? [] : functionDeclaration.typeParameters,
			typeConstraints, parameters, resultType);
	}

	static function fieldAccessName(access:Null<AstFieldAccess>):Null<String>
		return access == null ? null : switch access {
			case DefaultAccess: "default";
			case NullAccess: "null";
			case NeverAccess: "never";
			case GetAccess: "get";
			case SetAccess: "set";
			case DynamicAccess: "dynamic";
		};

	static function simpleTypePayload(type:AstType):Null<compiler.syntax.SyntaxTree.SyntaxTypePayload>
		return switch type {
			case IntType: compiler.syntax.SyntaxTree.SyntaxTypePayload.IntType;
			case BoolType: compiler.syntax.SyntaxTree.SyntaxTypePayload.BoolType;
			case FloatType: compiler.syntax.SyntaxTree.SyntaxTypePayload.FloatType;
			case StringType: compiler.syntax.SyntaxTree.SyntaxTypePayload.StringType;
			case VoidType: compiler.syntax.SyntaxTree.SyntaxTypePayload.VoidType;
			case InferredType: compiler.syntax.SyntaxTree.SyntaxTypePayload.InferredType;
			case ErrorType(_): compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType;
			case NativeAbstractType(declaration, tag): compiler.syntax.SyntaxTree.SyntaxTypePayload.NativeAbstractType(declaration, tag);
			case NamedType(name): compiler.syntax.SyntaxTree.SyntaxTypePayload.NamedType(name);
			case AppliedType(name, arguments):
				var lowered = simpleTypePayloads(arguments);
				lowered == null ? null : compiler.syntax.SyntaxTree.SyntaxTypePayload.AppliedType(name, lowered);
			case ArrayType(element):
				var lowered = simpleTypePayload(element);
				lowered == null ? null : compiler.syntax.SyntaxTree.SyntaxTypePayload.ArrayType(lowered);
			case MapType(key, value):
				var loweredKey = simpleTypePayload(key), loweredValue = simpleTypePayload(value);
				loweredKey == null || loweredValue == null ? null : compiler.syntax.SyntaxTree.SyntaxTypePayload.MapType(loweredKey, loweredValue);
			case NullableType(element):
				var lowered = simpleTypePayload(element);
				lowered == null ? null : compiler.syntax.SyntaxTree.SyntaxTypePayload.NullableType(lowered);
			case FunctionType(arguments, result):
				var loweredArguments = simpleTypePayloads(arguments), loweredResult = simpleTypePayload(result);
				loweredArguments == null || loweredResult == null ? null
					: compiler.syntax.SyntaxTree.SyntaxTypePayload.FunctionType(loweredArguments, loweredResult);
			case AnonymousType(fields):
				var loweredFields:Array<compiler.syntax.SyntaxTree.SyntaxAnonymousFieldPayload> = [];
				for (field in fields) {
					var lowered = simpleTypePayload(field.type);
					if (lowered == null)
						return null;
					loweredFields.push({name: field.name, type: lowered, optional: field.optional, span: field.span});
				}
				compiler.syntax.SyntaxTree.SyntaxTypePayload.AnonymousType(loweredFields);
		};

	static function simpleTypePayloads(types:Array<AstType>):Null<Array<compiler.syntax.SyntaxTree.SyntaxTypePayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload> = [];
		for (type in types) {
			var payload = simpleTypePayload(type);
			if (payload == null)
				return null;
			result.push(payload);
		}
		return result;
	}

	static function simpleTypeConstraintPayloads(constraints:Null<Array<compiler.syntax.Ast.AstTypeConstraint>>):Null<Array<compiler.syntax.SyntaxTree.SyntaxTypeConstraintPayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxTypeConstraintPayload> = [];
		if (constraints == null)
			return result;
		for (constraint in constraints) {
			var type = simpleTypePayload(constraint.type);
			if (type == null)
				return null;
			result.push({parameter: constraint.parameter, type: type});
		}
		return result;
	}

	function rememberExpression(expression:AstExpression,
			payload:Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload>):AstExpression {
		if (payload != null)
			parserExpressionPayloads.set(expressionPayloadKey(expression), payload);
		return expression;
	}

	function expressionPayload(expression:AstExpression):Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> {
		var payload = parserExpressionPayloads.get(expressionPayloadKey(expression));
		return payload == null ? simpleExpressionPayload(expression) : payload;
	}

	static inline function expressionPayloadKey(expression:AstExpression):String {
		var span = expressionSpan(expression);
		return '${span.start}:${span.end}';
	}

	function expressionPayloads(expressions:Array<AstExpression>):Null<Array<compiler.syntax.SyntaxTree.SyntaxExpressionPayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> = [];
		for (expression in expressions) {
			var payload = expressionPayload(expression);
			if (payload == null)
				return null;
			result.push(payload);
		}
		return result;
	}

	function rememberBinary(expression:AstExpression, operation:compiler.syntax.SyntaxTree.SyntaxBinaryOperator,
			left:AstExpression, right:AstExpression):AstExpression {
		var leftPayload = expressionPayload(left), rightPayload = expressionPayload(right),
			payload = leftPayload == null || rightPayload == null ? null
				: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload);
		return rememberExpression(expression, payload);
	}

	function rememberUnary(expression:AstExpression, operation:compiler.syntax.SyntaxTree.SyntaxUnaryOperator,
			value:AstExpression):AstExpression {
		var valuePayload = expressionPayload(value),
			payload = valuePayload == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Unary(operation, valuePayload);
		return rememberExpression(expression, payload);
	}

	function parserArgumentPayloads(arguments:Array<AstArgument>):Null<Array<compiler.syntax.SyntaxTree.SyntaxArgumentPayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxArgumentPayload> = [];
		for (argument in arguments) {
			var type = simpleTypePayload(argument.type), defaultValue = argument.defaultValue == null ? null : expressionPayload(argument.defaultValue);
			if (type == null || argument.defaultValue != null && defaultValue == null)
				return null;
			result.push({name: argument.name, type: type, optional: argument.optional == true, defaultValue: defaultValue});
		}
		return result;
	}

	function parserStatementPayload(statement:AstStatement):Null<compiler.syntax.SyntaxTree.SyntaxStatementPayload>
		return switch statement {
			case ErrorStatement(_): compiler.syntax.SyntaxTree.SyntaxStatementPayload.Error;
			case UninitializedDeclaration(name, type, _):
				var typePayload = simpleTypePayload(type);
				typePayload == null ? null : compiler.syntax.SyntaxTree.SyntaxStatementPayload.UninitializedDeclaration(name, typePayload);
			case VarDeclaration(name, type, initializer, _):
				var typePayload = type == null ? null : simpleTypePayload(type), initializerPayload = expressionPayload(initializer);
				type != null && typePayload == null || initializerPayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.VarDeclaration(name, typePayload, initializerPayload);
			case Assignment(name, expression, _):
				var value = expressionPayload(expression);
				value == null ? null : compiler.syntax.SyntaxTree.SyntaxStatementPayload.Assignment(name, value);
			case IndexAssignment(array, index, expression, _):
				var loweredArray = expressionPayload(array), loweredIndex = expressionPayload(index), loweredExpression = expressionPayload(expression);
				loweredArray == null || loweredIndex == null || loweredExpression == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.IndexAssignment(loweredArray, loweredIndex, loweredExpression);
			case FieldAssignment(object, field, expression, _):
				var loweredObject = expressionPayload(object), loweredExpression = expressionPayload(expression);
				loweredObject == null || loweredExpression == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.FieldAssignment(loweredObject, field, loweredExpression);
			case Break(_): compiler.syntax.SyntaxTree.SyntaxStatementPayload.Break;
			case Continue(_): compiler.syntax.SyntaxTree.SyntaxStatementPayload.Continue;
			case ReturnVoid(_): compiler.syntax.SyntaxTree.SyntaxStatementPayload.ReturnVoid;
			case Return(expression, _):
				var value = expressionPayload(expression);
				value == null ? null : compiler.syntax.SyntaxTree.SyntaxStatementPayload.Return(value);
			case AstStatement.If(condition, thenBranch, elseBranch, _):
				var conditionPayload = expressionPayload(condition), thenPayload = parserStatementPayloads(thenBranch),
					elsePayload = parserStatementPayloads(elseBranch);
				conditionPayload == null || thenPayload == null || elsePayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.IfBranch(conditionPayload, thenPayload, elsePayload);
			case AstStatement.While(condition, body, _):
				var conditionPayload = expressionPayload(condition), bodyPayload = parserStatementPayloads(body);
				conditionPayload == null || bodyPayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.WhileLoop(conditionPayload, bodyPayload);
			case AstStatement.DoWhile(body, condition, _):
				var conditionPayload = expressionPayload(condition), bodyPayload = parserStatementPayloads(body);
				conditionPayload == null || bodyPayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.DoWhileLoop(bodyPayload, conditionPayload);
			case AstStatement.ForIn(keyName, valueName, iterable, body, _):
				var iterablePayload = expressionPayload(iterable), bodyPayload = parserStatementPayloads(body);
				iterablePayload == null || bodyPayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.ForLoop(keyName, valueName, iterablePayload, bodyPayload);
			case AstStatement.Throw(expression, _):
				var value = expressionPayload(expression);
				value == null ? null : compiler.syntax.SyntaxTree.SyntaxStatementPayload.Throw(value);
			case AstStatement.Try(tryBranch, catches, _):
				var loweredTry = parserStatementPayloads(tryBranch), loweredCatches = parserCatchPayloads(catches);
				loweredTry == null || loweredCatches == null ? null : compiler.syntax.SyntaxTree.SyntaxStatementPayload.Try(loweredTry, loweredCatches);
			case AstStatement.Switch(expression, cases, defaultBranch, hasDefault, _):
				var loweredExpression = expressionPayload(expression), loweredCases = parserSwitchCasePayloads(cases), loweredDefault = parserStatementPayloads(defaultBranch);
				loweredExpression == null || loweredCases == null || loweredDefault == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.Switch(loweredExpression, loweredCases, loweredDefault, hasDefault);
			case Increment(name, delta, _): compiler.syntax.SyntaxTree.SyntaxStatementPayload.Increment(name, delta);
			case Expression(expression, _):
				var value = expressionPayload(expression);
				value == null ? null : compiler.syntax.SyntaxTree.SyntaxStatementPayload.Expression(value);
			default: null;
		};

	function parserStatementPayloads(statements:Array<AstStatement>):Null<Array<compiler.syntax.SyntaxTree.SyntaxStatementPayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxStatementPayload> = [];
		for (statement in statements) {
			var payload = parserStatementPayload(statement);
			if (payload == null)
				return null;
			result.push(payload);
		}
		return result;
	}

	function parserCatchPayloads(catches:Array<compiler.syntax.Ast.AstCatch>):Null<Array<compiler.syntax.SyntaxTree.SyntaxCatchPayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxCatchPayload> = [];
		for (catchClause in catches) {
			var type = simpleTypePayload(catchClause.type), statements = parserStatementPayloads(catchClause.statements);
			if (type == null || statements == null)
				return null;
			result.push({name: catchClause.name, type: type, statements: statements});
		}
		return result;
	}

	function parserSwitchCasePayloads(cases:Array<compiler.syntax.Ast.AstSwitchCase>):Null<Array<compiler.syntax.SyntaxTree.SyntaxSwitchCasePayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxSwitchCasePayload> = [];
		for (caseClause in cases) {
			var value = expressionPayload(caseClause.value), guard = caseClause.guard == null ? null : expressionPayload(caseClause.guard), statements = parserStatementPayloads(caseClause.statements);
			if (value == null || caseClause.guard != null && guard == null || statements == null)
				return null;
			result.push({value: value, guard: guard, statements: statements});
		}
		return result;
	}

	function parserLambdaPayload(arguments:Array<AstArgument>, body:Array<AstStatement>):Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> {
		var argumentPayloads = parserArgumentPayloads(arguments), statementPayloads = parserStatementPayloads(body);
		return argumentPayloads == null || statementPayloads == null ? null
			: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Lambda(argumentPayloads, statementPayloads);
	}

	function rememberBlockExpression(statements:Array<AstStatement>, result:AstExpression, span:SourceSpan):AstExpression {
		var statementPayloads = parserStatementPayloads(statements), resultPayload = expressionPayload(result),
			payload:Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> = statementPayloads == null || resultPayload == null ? null
				: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Block(statementPayloads, resultPayload);
		return rememberExpression(BlockExpression(statements, result, span), payload);
	}

	static function simpleExpressionPayload(expression:AstExpression):Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload>
		return switch expression {
			case IntegerLiteral(value, _): compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Integer(value);
			case FloatLiteral(value, _): compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Float(value);
			case StringLiteral(value, _): compiler.syntax.SyntaxTree.SyntaxExpressionPayload.String(value);
			case BoolLiteral(value, _): compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Bool(value);
			case NullLiteral(_): compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NullValue;
			case Unreachable(_): compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Unreachable;
			case EmptyExpression(_): compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Empty;
			case ErrorExpression(_): compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Error;
			case Variable(name, _): compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Variable(name);
			case Member(object, name, _):
				var lowered = simpleExpressionPayload(object);
				lowered == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Member(lowered, name);
			case Add(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Add, left, right);
			case Sub(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Sub, left, right);
			case Mul(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Mul, left, right);
			case Div(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Div, left, right);
			case Mod(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Mod, left, right);
			case BitAnd(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitAnd, left, right);
			case BitXor(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitXor, left, right);
			case BitOr(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitOr, left, right);
			case ShiftLeft(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.ShiftLeft, left, right);
			case ShiftRight(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.ShiftRight, left, right);
			case UnsignedShiftRight(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.UnsignedShiftRight, left, right);
			case Less(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Less, left, right);
			case LessEqual(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.LessEqual, left, right);
			case Greater(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Greater, left, right);
			case GreaterEqual(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.GreaterEqual, left, right);
			case Equal(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Equal, left, right);
			case NotEqual(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.NotEqual, left, right);
			case And(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.And, left, right);
			case Or(left, right, _): binaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Or, left, right);
			case Negate(value, _): unaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxUnaryOperator.Negate, value);
			case Not(value, _): unaryExpressionPayload(compiler.syntax.SyntaxTree.SyntaxUnaryOperator.Not, value);
			case Conditional(condition, whenTrue, whenFalse, _):
				var loweredCondition = simpleExpressionPayload(condition), loweredTrue = simpleExpressionPayload(whenTrue), loweredFalse = simpleExpressionPayload(whenFalse);
				loweredCondition == null || loweredTrue == null || loweredFalse == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Conditional(loweredCondition, loweredTrue, loweredFalse);
			case BlockExpression(statements, result, _):
				var loweredStatements = simpleStatementPayloads(statements), loweredResult = simpleExpressionPayload(result);
				loweredStatements == null || loweredResult == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Block(loweredStatements, loweredResult);
			case ThrowExpression(value, _):
				var lowered = simpleExpressionPayload(value);
				lowered == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Throw(lowered);
			case Cast(value, target, _):
				var loweredValue = simpleExpressionPayload(value), loweredTarget = target == null ? null : simpleTypePayload(target);
				loweredValue == null || target != null && loweredTarget == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Cast(loweredValue, loweredTarget);
			case SwitchExpression(value, cases, defaultExpression, _):
				var loweredValue = simpleExpressionPayload(value), loweredCases = simpleSwitchExpressionCases(cases), loweredDefault = defaultExpression == null ? null : simpleExpressionPayload(defaultExpression);
				loweredValue == null || loweredCases == null || defaultExpression != null && loweredDefault == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Switch(loweredValue, loweredCases, loweredDefault);
			case ObjectLiteral(fields, _):
				var loweredFields:Array<compiler.syntax.SyntaxTree.SyntaxObjectFieldPayload> = [];
				for (field in fields) {
					var value = simpleExpressionPayload(field.value);
					if (value == null)
						return null;
					loweredFields.push({name: field.name, value: value});
				}
				compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Object(loweredFields);
			case ArrayLiteral(values, _):
				var lowered = simpleExpressionPayloads(values);
				lowered == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Array(lowered);
			case MapLiteral(entries, _):
				var loweredEntries:Array<compiler.syntax.SyntaxTree.SyntaxMapEntryPayload> = [];
				for (entry in entries) {
					var key = simpleExpressionPayload(entry.key), value = simpleExpressionPayload(entry.value);
					if (key == null || value == null)
						return null;
					loweredEntries.push({key: key, value: value});
				}
				compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Map(loweredEntries);
			case ArrayComprehension(keyName, valueName, iterable, condition, value, _):
				var loweredIterable = simpleExpressionPayload(iterable), loweredCondition = condition == null ? null : simpleExpressionPayload(condition), loweredValue = simpleExpressionPayload(value);
				loweredIterable == null || condition != null && loweredCondition == null || loweredValue == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.ArrayComprehension(keyName, valueName, loweredIterable, loweredCondition, loweredValue);
			case MapComprehension(keyName, valueName, iterable, condition, key, value, _):
				var loweredIterable = simpleExpressionPayload(iterable), loweredCondition = condition == null ? null : simpleExpressionPayload(condition), loweredKey = simpleExpressionPayload(key), loweredValue = simpleExpressionPayload(value);
				loweredIterable == null || condition != null && loweredCondition == null || loweredKey == null || loweredValue == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.MapComprehension(keyName, valueName, loweredIterable, loweredCondition, loweredKey, loweredValue);
			case Range(start, end, _):
				var loweredStart = simpleExpressionPayload(start), loweredEnd = simpleExpressionPayload(end);
				loweredStart == null || loweredEnd == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Range(loweredStart, loweredEnd);
			case Call(name, arguments, _):
				var lowered = simpleExpressionPayloads(arguments);
				lowered == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Call(name, lowered);
			case NativeLayoutQuery(kind, type, field, _):
				var lowered = simpleTypePayload(type);
				lowered == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NativeLayoutQuery(syntaxNativeLayoutKind(kind), lowered, field);
			case ClosureCall(callee, arguments, _):
				var loweredCallee = simpleExpressionPayload(callee), loweredArguments = simpleExpressionPayloads(arguments);
				loweredCallee == null || loweredArguments == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.ClosureCall(loweredCallee, loweredArguments);
			case MethodCall(object, name, arguments, _):
				var loweredObject = simpleExpressionPayload(object), loweredArguments = simpleExpressionPayloads(arguments);
				loweredObject == null || loweredArguments == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.MethodCall(loweredObject, name, loweredArguments);
			case New(typeName, arguments, _):
				var lowered = simpleExpressionPayloads(arguments);
				lowered == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.New(typeName, lowered);
			case NewGeneric(typeName, typeArguments, arguments, _):
				var loweredTypes = simpleTypePayloads(typeArguments), loweredArguments = simpleExpressionPayloads(arguments);
				loweredTypes == null || loweredArguments == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NewGeneric(typeName, loweredTypes, loweredArguments);
			case NewArray(element, length, _):
				var loweredElement = simpleTypePayload(element), loweredLength = simpleExpressionPayload(length);
				loweredElement == null || loweredLength == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NewArray(loweredElement, loweredLength);
			case NewMap(key, value, _):
				var loweredKey = simpleTypePayload(key), loweredValue = simpleTypePayload(value);
				loweredKey == null || loweredValue == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NewMap(loweredKey, loweredValue);
			case Index(array, index, _):
				var loweredArray = simpleExpressionPayload(array), loweredIndex = simpleExpressionPayload(index);
				loweredArray == null || loweredIndex == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Index(loweredArray, loweredIndex);
			case PostfixIncrement(target, delta, _):
				var lowered = simpleExpressionPayload(target);
				lowered == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.PostfixIncrement(lowered, delta);
			case Lambda(arguments, statements, _):
				var loweredArguments = simpleArgumentPayloads(arguments), loweredStatements = simpleStatementPayloads(statements);
				loweredArguments == null || loweredStatements == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Lambda(loweredArguments, loweredStatements);
		};

	static function simpleExpressionPayloads(expressions:Array<AstExpression>):Null<Array<compiler.syntax.SyntaxTree.SyntaxExpressionPayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> = [];
		for (expression in expressions) {
			var payload = simpleExpressionPayload(expression);
			if (payload == null)
				return null;
			result.push(payload);
		}
		return result;
	}

	static function simpleArgumentPayloads(arguments:Array<AstArgument>):Null<Array<compiler.syntax.SyntaxTree.SyntaxArgumentPayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxArgumentPayload> = [];
		for (argument in arguments) {
			var type = simpleTypePayload(argument.type), defaultValue = argument.defaultValue == null ? null : simpleExpressionPayload(argument.defaultValue);
			if (type == null || argument.defaultValue != null && defaultValue == null)
				return null;
			result.push({name: argument.name, type: type, optional: argument.optional == true, defaultValue: defaultValue});
		}
		return result;
	}

	static function simpleSwitchExpressionCases(cases:Array<compiler.syntax.Ast.AstSwitchExpressionCase>):Null<Array<compiler.syntax.SyntaxTree.SyntaxSwitchExpressionCasePayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxSwitchExpressionCasePayload> = [];
		for (entry in cases) {
			var value = simpleExpressionPayload(entry.value), guard = entry.guard == null ? null : simpleExpressionPayload(entry.guard), loweredResult = simpleExpressionPayload(entry.result);
			if (value == null || entry.guard != null && guard == null || loweredResult == null)
				return null;
			result.push({value: value, guard: guard, result: loweredResult});
		}
		return result;
	}

	static function syntaxNativeLayoutKind(kind:NativeLayoutQueryKind):compiler.syntax.SyntaxTree.SyntaxNativeLayoutQueryKind
		return switch kind {
			case SizeOf: compiler.syntax.SyntaxTree.SyntaxNativeLayoutQueryKind.SizeOf;
			case AlignOf: compiler.syntax.SyntaxTree.SyntaxNativeLayoutQueryKind.AlignOf;
			case OffsetOf: compiler.syntax.SyntaxTree.SyntaxNativeLayoutQueryKind.OffsetOf;
		};

	static function binaryExpressionPayload(operation:compiler.syntax.SyntaxTree.SyntaxBinaryOperator, left:AstExpression,
			right:AstExpression):Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> {
		var leftPayload = simpleExpressionPayload(left), rightPayload = simpleExpressionPayload(right);
		return leftPayload == null || rightPayload == null ? null
			: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload);
	}

	static function unaryExpressionPayload(operation:compiler.syntax.SyntaxTree.SyntaxUnaryOperator, value:AstExpression):Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> {
		var valuePayload = simpleExpressionPayload(value);
		return valuePayload == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Unary(operation, valuePayload);
	}

	static function simpleStatementPayload(statement:AstStatement):Null<compiler.syntax.SyntaxTree.SyntaxStatementPayload>
		return switch statement {
			case ErrorStatement(_): compiler.syntax.SyntaxTree.SyntaxStatementPayload.Error;
			case UninitializedDeclaration(name, type, _):
				var typePayload = simpleTypePayload(type);
				typePayload == null ? null : compiler.syntax.SyntaxTree.SyntaxStatementPayload.UninitializedDeclaration(name, typePayload);
			case VarDeclaration(name, type, initializer, _):
				var typePayload = type == null ? null : simpleTypePayload(type), initializerPayload = simpleExpressionPayload(initializer);
				type != null && typePayload == null || initializerPayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.VarDeclaration(name, typePayload, initializerPayload);
			case Assignment(name, expression, _):
				var value = simpleExpressionPayload(expression);
				value == null ? null : compiler.syntax.SyntaxTree.SyntaxStatementPayload.Assignment(name, value);
			case IndexAssignment(array, index, expression, _):
				var loweredArray = simpleExpressionPayload(array), loweredIndex = simpleExpressionPayload(index), loweredExpression = simpleExpressionPayload(expression);
				loweredArray == null || loweredIndex == null || loweredExpression == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.IndexAssignment(loweredArray, loweredIndex, loweredExpression);
			case FieldAssignment(object, field, expression, _):
				var loweredObject = simpleExpressionPayload(object), loweredExpression = simpleExpressionPayload(expression);
				loweredObject == null || loweredExpression == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.FieldAssignment(loweredObject, field, loweredExpression);
			case Break(_): compiler.syntax.SyntaxTree.SyntaxStatementPayload.Break;
			case Continue(_): compiler.syntax.SyntaxTree.SyntaxStatementPayload.Continue;
			case ReturnVoid(_): compiler.syntax.SyntaxTree.SyntaxStatementPayload.ReturnVoid;
			case Return(expression, _):
				var value = simpleExpressionPayload(expression);
				value == null ? null : compiler.syntax.SyntaxTree.SyntaxStatementPayload.Return(value);
			case AstStatement.If(condition, thenBranch, elseBranch, _):
				var conditionPayload = simpleExpressionPayload(condition), thenPayload = simpleStatementPayloads(thenBranch),
					elsePayload = simpleStatementPayloads(elseBranch);
				conditionPayload == null || thenPayload == null || elsePayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.IfBranch(conditionPayload, thenPayload, elsePayload);
			case AstStatement.While(condition, body, _):
				var conditionPayload = simpleExpressionPayload(condition), bodyPayload = simpleStatementPayloads(body);
				conditionPayload == null || bodyPayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.WhileLoop(conditionPayload, bodyPayload);
			case AstStatement.DoWhile(body, condition, _):
				var conditionPayload = simpleExpressionPayload(condition), bodyPayload = simpleStatementPayloads(body);
				conditionPayload == null || bodyPayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.DoWhileLoop(bodyPayload, conditionPayload);
			case AstStatement.ForIn(keyName, valueName, iterable, body, _):
				var iterablePayload = simpleExpressionPayload(iterable), bodyPayload = simpleStatementPayloads(body);
				iterablePayload == null || bodyPayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.ForLoop(keyName, valueName, iterablePayload, bodyPayload);
			case AstStatement.Throw(expression, _):
				var value = simpleExpressionPayload(expression);
				value == null ? null : compiler.syntax.SyntaxTree.SyntaxStatementPayload.Throw(value);
			case AstStatement.Try(tryBranch, catches, _):
				var loweredTry = simpleStatementPayloads(tryBranch), loweredCatches = simpleCatchPayloads(catches);
				loweredTry == null || loweredCatches == null ? null : compiler.syntax.SyntaxTree.SyntaxStatementPayload.Try(loweredTry, loweredCatches);
			case AstStatement.Switch(expression, cases, defaultBranch, hasDefault, _):
				var loweredExpression = simpleExpressionPayload(expression), loweredCases = simpleSwitchCasePayloads(cases), loweredDefault = simpleStatementPayloads(defaultBranch);
				loweredExpression == null || loweredCases == null || loweredDefault == null ? null
					: compiler.syntax.SyntaxTree.SyntaxStatementPayload.Switch(loweredExpression, loweredCases, loweredDefault, hasDefault);
			case Increment(name, delta, _): compiler.syntax.SyntaxTree.SyntaxStatementPayload.Increment(name, delta);
			case Expression(expression, _):
				var value = simpleExpressionPayload(expression);
				value == null ? null : compiler.syntax.SyntaxTree.SyntaxStatementPayload.Expression(value);
			default: null;
		};

	static function simpleStatementPayloads(statements:Array<AstStatement>):Null<Array<compiler.syntax.SyntaxTree.SyntaxStatementPayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxStatementPayload> = [];
		for (statement in statements) {
			var payload = simpleStatementPayload(statement);
			if (payload == null)
				return null;
			result.push(payload);
		}
		return result;
	}

	static function simpleCatchPayloads(catches:Array<compiler.syntax.Ast.AstCatch>):Null<Array<compiler.syntax.SyntaxTree.SyntaxCatchPayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxCatchPayload> = [];
		for (catchClause in catches) {
			var type = simpleTypePayload(catchClause.type), statements = simpleStatementPayloads(catchClause.statements);
			if (type == null || statements == null)
				return null;
			result.push({name: catchClause.name, type: type, statements: statements});
		}
		return result;
	}

	static function simpleSwitchCasePayloads(cases:Array<compiler.syntax.Ast.AstSwitchCase>):Null<Array<compiler.syntax.SyntaxTree.SyntaxSwitchCasePayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxSwitchCasePayload> = [];
		for (caseClause in cases) {
			var value = simpleExpressionPayload(caseClause.value), guard = caseClause.guard == null ? null : simpleExpressionPayload(caseClause.guard), statements = simpleStatementPayloads(caseClause.statements);
			if (value == null || caseClause.guard != null && guard == null || statements == null)
				return null;
			result.push({value: value, guard: guard, statements: statements});
		}
		return result;
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
			typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeConstraintPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypeConstraintPayload> = [],
			typeParameters = parseTypeParameters(typeConstraints, typeConstraintPayloads), bases = [],
			basePayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload> = [];
		if (match(TokenKind.Extends)) {
			var parsedBase = recovering && (check(TokenKind.LeftBrace) || isDeclarationBoundary(current()))
				? parsedType(missingType("base interface type"), compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType)
				: parseDelimitedTypeResult(TokenKind.LeftBrace);
			bases.push(parsedBase.ast);
			basePayloads.push(parsedBase.payload);
			while (match(TokenKind.Comma)) {
				var nextBase = recovering && (check(TokenKind.LeftBrace) || isDeclarationBoundary(current()))
					? parsedType(missingType("base interface type"), compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType)
					: parseDelimitedTypeResult(TokenKind.LeftBrace);
				bases.push(nextBase.ast);
				basePayloads.push(nextBase.payload);
			}
		}
		if (recovering && isDeclarationBoundary(current())) {
			recordExpected("interface body");
			var recoveredInterface:AstInterface = {
				name: name,
				typeParameters: typeParameters,
				typeConstraints: typeConstraints,
				bases: bases,
				methods: [],
				span: start.merge(previous().span)
			};
			parserPayloads.set(recoveredInterface.span.start, SyntaxNodePayload.InterfaceHeader(name, typeParameters,
				typeConstraintPayloads, basePayloads));
			return recoveredInterface;
		}
		var interfaceBodyStart = consume(TokenKind.LeftBrace).span;
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
					typeConstraintPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypeConstraintPayload> = [],
					typeParameters = parseTypeParameters(typeConstraints, typeConstraintPayloads),
					arguments = [], parameterPayloads:Array<compiler.syntax.SyntaxTree.SyntaxArgumentPayload> = [];
				var parameterStart:Null<SourceSpan> = null;
				if (recovering && (recoveringAtEnd() || isDeclarationBoundary(current())))
					recordExpected("left parenthesis");
				else {
					parameterStart = consume(TokenKind.LeftParen).span;
					while (!check(TokenKind.RightParen) && !recoveringAtEnd() && !canInsert(TokenKind.RightParen)) {
						if (check(TokenKind.Comma)) {
							recordExpected("parameter");
							advance();
							continue;
						}
						var optional = match(TokenKind.Question),
							argumentName = consumeDeclarationName("parameter");
						consume(TokenKind.Colon);
						var parsedArgumentType = parseTypeResult();
						arguments.push({
							name: argumentName,
							type: parsedArgumentType.ast,
							span: previous().span,
							optional: optional,
							defaultValue: null
						});
						parameterPayloads.push({name: argumentName, type: parsedArgumentType.payload,
							optional: optional, defaultValue: null});
						if (!match(TokenKind.Comma))
							break;
					}
					var parameterEnd = consume(TokenKind.RightParen).span;
					if (parameterStart != null)
						recordCstNode(SyntaxKind.ParameterList, parameterStart.merge(parameterEnd));
				}
				var parsedResult = match(TokenKind.Colon)
					? parseTypeResult()
					: recovering ? parsedType(missingType("interface method return type"), compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType)
						: parsedType(failType("Interface methods require a return type"), compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType),
					result = parsedResult.ast,
					end = consume(TokenKind.Semicolon).span;
				var method:compiler.syntax.Ast.AstFunction = {
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
				};
				methods.push(method);
				if (methodMetadata == null || methodMetadata.length == 0) {
					var payload = SyntaxNodePayload.FunctionHeaderRich(methodName, false, false, typeParameters,
						typeConstraintPayloads, parameterPayloads, parsedResult.payload);
					parserPayloads.set(method.span.start, payload);
				}
			} catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				synchronizeInterfaceMember(bodyStart, memberStart);
			}
		}
		var end = consume(TokenKind.RightBrace).span;
		recordCstNode(SyntaxKind.Block, interfaceBodyStart.merge(end));
		var interfaceDeclaration:AstInterface = {
			name: name,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			bases: bases,
			methods: methods,
			span: start.merge(end)
		};
		parserPayloads.set(interfaceDeclaration.span.start, SyntaxNodePayload.InterfaceHeader(name, typeParameters,
			typeConstraintPayloads, basePayloads));
		return interfaceDeclaration;
	}

	function parseStatement():AstStatement {
		if (match(TokenKind.Function)) {
			var start = previous().span,
				name = consumeDeclarationName("local function");
			var parameterStart = consume(TokenKind.LeftParen).span;
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
			var parameterEnd = consume(TokenKind.RightParen).span;
			recordCstNode(SyntaxKind.ParameterList, parameterStart.merge(parameterEnd));
			var result = match(TokenKind.Colon) ? parseType() : null,
				body = parseStatementOrBlock(),
				end = body.length == 0 ? previous().span : statementSpan(body[body.length - 1]),
				span = start.merge(end),
				declared = result == null ? null : FunctionType([for (argument in arguments) argument.type], result);
			var statement = VarDeclaration(name, declared, Lambda(arguments, body, span), span);
			recordStatementCst(SyntaxKind.VariableDeclaration, statement, span);
			return statement;
		}
		if (match(TokenKind.Break)) {
			var start = previous().span;
			var span = start.merge(consume(TokenKind.Semicolon).span);
			recordCstNode(SyntaxKind.BreakStatement, span,
				SyntaxNodePayload.Statement(compiler.syntax.SyntaxTree.SyntaxStatementPayload.Break));
			return Break(span);
		}
		if (match(TokenKind.Continue)) {
			var start = previous().span;
			var span = start.merge(consume(TokenKind.Semicolon).span);
			recordCstNode(SyntaxKind.ContinueStatement, span,
				SyntaxNodePayload.Statement(compiler.syntax.SyntaxTree.SyntaxStatementPayload.Continue));
			return Continue(span);
		}
		if (match(TokenKind.Var)) {
			var start = previous().span;
			var name = consumeDeclarationName("local");
			var type = match(TokenKind.Colon) ? parseType() : null;
			consume(TokenKind.Assign);
			var initializer = parseExpression();
			var end = expressionEnd(initializer);
			var statement = VarDeclaration(name, type, initializer, start.merge(end));
			recordStatementCst(SyntaxKind.VariableDeclaration, statement, statementSpan(statement));
			return statement;
		}
		if (match(TokenKind.Return)) {
			var start = previous().span;
			if (check(TokenKind.Semicolon)) {
				var span = start.merge(consume(TokenKind.Semicolon).span);
				recordCstNode(SyntaxKind.ReturnStatement, span,
					SyntaxNodePayload.Statement(compiler.syntax.SyntaxTree.SyntaxStatementPayload.ReturnVoid));
				return ReturnVoid(span);
			}
			var expression = parseExpression();
			var end = expressionEnd(expression);
			var span = start.merge(end), payload = expressionPayload(expression);
			if (payload != null)
				recordCstNode(SyntaxKind.ReturnStatement, span,
					SyntaxNodePayload.Statement(compiler.syntax.SyntaxTree.SyntaxStatementPayload.Return(payload)));
			return Return(expression, span);
		}
		if (match(TokenKind.Throw)) {
			var start = previous().span,
				expression = parseExpression(),
				end = expressionEnd(expression);
			var statement = AstStatement.Throw(expression, start.merge(end));
			recordStatementCst(SyntaxKind.ThrowStatement, statement, statementSpan(statement));
			return statement;
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
			var statement = AstStatement.Try(tryBranch, catches, start.merge(end));
			recordStatementCst(SyntaxKind.TryStatement, statement, statementSpan(statement));
			return statement;
		}
		if (match(TokenKind.Switch)) {
			var start = previous().span;
			var expression:AstExpression;
			if (match(TokenKind.LeftParen)) {
				expression = parseExpression();
				consume(TokenKind.RightParen);
			} else
				expression = parseExpression();
			var switchBodyStart = consume(TokenKind.LeftBrace).span;
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
			recordCstNode(SyntaxKind.Block, switchBodyStart.merge(end));
			if (match(TokenKind.Semicolon))
				end = previous().span;
			var statement = AstStatement.Switch(expression, cases, defaultBranch, hasDefault, start.merge(end));
			recordStatementCst(SyntaxKind.SwitchStatement, statement, statementSpan(statement));
			return statement;
		}
		if (check(TokenKind.Identifier) || check(TokenKind.This)) {
			var saved = position, target = parseOr();
			if (match(TokenKind.Increment) || match(TokenKind.Decrement)) {
				var delta = previous().kind == TokenKind.Increment ? 1 : -1,
					end = consume(TokenKind.Semicolon).span;
				var statement:AstStatement = switch target {
					case Variable(name, _):
						Increment(name, delta, expressionSpan(target).merge(end));
					default: throw new CompileError(new Diagnostic("E0002", "Increment target must be a variable", expressionSpan(target)));
				};
				recordStatementCst(SyntaxKind.IncrementStatement, statement, statementSpan(statement));
				return statement;
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
						case 1: rememberBinary(Add(target, value, operationSpan), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Add, target, value);
						case 2: rememberBinary(Sub(target, value, operationSpan), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Sub, target, value);
						case 3: rememberBinary(Mul(target, value, operationSpan), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Mul, target, value);
						case 4: rememberBinary(Div(target, value, operationSpan), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Div, target, value);
						case 5: rememberBinary(Mod(target, value, operationSpan), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Mod, target, value);
						case 6: rememberBinary(BitAnd(target, value, operationSpan), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitAnd, target, value);
						case 7: rememberBinary(BitOr(target, value, operationSpan), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitOr, target, value);
						default: rememberBinary(BitXor(target, value, operationSpan), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitXor, target, value);
					},
					assignment = switch target {
						case Variable(name, _): Assignment(name, assigned, expressionSpan(target).merge(end));
						case Index(array, offset, _): IndexAssignment(array, offset, assigned, expressionSpan(target).merge(end));
						case Member(object, field, _): FieldAssignment(object, field, assigned, expressionSpan(target).merge(end));
						default:
							throw new CompileError(new Diagnostic("E0002", "Assignment target must be a variable, field, or array element",
								expressionSpan(target)));
					};
				if (bindings.length == 0) {
					recordStatementCst(SyntaxKind.AssignmentStatement, assignment, statementSpan(assignment));
					return assignment;
				}
				bindings.push(assignment);
				var statement = Expression(BlockExpression(bindings, IntegerLiteral(0, span), span), span);
				recordStatementCst(SyntaxKind.ExpressionStatement, statement, span);
				return statement;
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
			var statement = AstStatement.If(condition, thenBranch, elseBranch, start.merge(end)), payload = parserStatementPayload(statement);
			if (payload != null)
				recordCstNode(SyntaxKind.IfStatement, start.merge(end), SyntaxNodePayload.Statement(payload));
			return statement;
		}
		if (match(TokenKind.While)) {
			var start = previous().span;
			consume(TokenKind.LeftParen);
			var condition = parseExpression();
			consume(TokenKind.RightParen);
			var body = parseStatementOrBlock();
			var end = statementEnd(body);
			var statement = AstStatement.While(condition, body, start.merge(end)), payload = parserStatementPayload(statement);
			if (payload != null)
				recordCstNode(SyntaxKind.WhileStatement, start.merge(end), SyntaxNodePayload.Statement(payload));
			return statement;
		}
		if (match(TokenKind.Do)) {
			var start = previous().span, body = parseDoWhileBody();
			consume(TokenKind.While);
			consume(TokenKind.LeftParen);
			var condition = parseExpression();
			consume(TokenKind.RightParen);
			var end = consume(TokenKind.Semicolon).span;
			var statement = AstStatement.DoWhile(body, condition, start.merge(end)), payload = parserStatementPayload(statement);
			if (payload != null)
				recordCstNode(SyntaxKind.DoWhileStatement, start.merge(end), SyntaxNodePayload.Statement(payload));
			return statement;
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
			var statement = ForIn(name, valueName, iterable, body, start.merge(end)), payload = parserStatementPayload(statement);
			if (payload != null)
				recordCstNode(SyntaxKind.ForStatement, start.merge(end), SyntaxNodePayload.Statement(payload));
			return statement;
		}
		var expression = parseExpression(), end = expressionEnd(expression), statement = Expression(expression, expressionSpan(expression).merge(end));
		recordStatementCst(SyntaxKind.ExpressionStatement, statement, statementSpan(statement));
		return statement;
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
		for (declaration in declarations)
			recordStatementCst(SyntaxKind.VariableDeclaration, declaration, statementSpan(declaration));
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
			var span = expressionSpan(expression).merge(expressionSpan(whenFalse));
			var conditionPayload = expressionPayload(expression), truePayload = expressionPayload(whenTrue), falsePayload = expressionPayload(whenFalse),
				payload = conditionPayload == null || truePayload == null || falsePayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Conditional(conditionPayload, truePayload, falsePayload);
			expression = rememberExpression(Conditional(expression, whenTrue, whenFalse, span), payload);
			recordCstNode(SyntaxKind.ConditionalExpression, span);
		}
		if (check(TokenKind.Assign) && peekKind(1) != TokenKind.Greater) {
			advance();
			var value = parseExpression(),
				span = expressionSpan(expression).merge(expressionSpan(value));
				expression = switch expression {
					case Variable(name, _): rememberBlockExpression([Assignment(name, value, span)], Variable(name, span), span);
					default: throw new CompileError(new Diagnostic("E0002", "Assignment expression target must be a variable", expressionSpan(expression)));
				};
			recordCstNode(SyntaxKind.AssignmentExpression, span);
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
			var startPayload = expressionPayload(expression), endPayload = expressionPayload(end),
				rangePayload = startPayload == null || endPayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Range(startPayload, endPayload);
			expression = rememberExpression(Range(expression, end, expressionSpan(expression).merge(expressionSpan(end))), rangePayload);
		}
		if (match(TokenKind.NullCoalesce)) {
			var fallback = parseNullCoalesce(),
				span = expressionSpan(expression).merge(expressionSpan(fallback)),
				localName = '$' + 'null-coalesce:${span.start}',
				local = Variable(localName, expressionSpan(expression));
			var localPayload = compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Variable(localName),
				nullValue = rememberExpression(NullLiteral(expressionSpan(local)), compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NullValue),
				equality = rememberBinary(Equal(local, nullValue, expressionSpan(local)), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Equal, local, nullValue),
				fallbackPayload = expressionPayload(fallback),
				conditionalPayload = fallbackPayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Conditional(
						compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Binary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Equal,
							localPayload, compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NullValue), fallbackPayload, localPayload),
				conditional = rememberExpression(Conditional(equality, fallback, local, span), conditionalPayload);
			return rememberBlockExpression([VarDeclaration(localName, null, expression, expressionSpan(expression))], conditional, span);
		}
		return expression;
	}

	function parseOr():AstExpression {
		var expression = parseAnd();
		while (match(TokenKind.OrOr)) {
			var right = parseAnd(),
				span = expressionSpan(expression).merge(expressionSpan(right));
			expression = rememberBinary(Or(expression, right, span), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Or, expression, right);
			recordCstNode(SyntaxKind.BinaryExpression, span);
		}
		return expression;
	}

	function parseAnd():AstExpression {
		var expression = parseComparison();
		while (match(TokenKind.AndAnd)) {
			var right = parseComparison(),
				span = expressionSpan(expression).merge(expressionSpan(right));
			expression = rememberBinary(And(expression, right, span), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.And, expression, right);
			recordCstNode(SyntaxKind.BinaryExpression, span);
		}
		return expression;
	}

	function parseBitOr():AstExpression {
		var expression = parseBitXor();
		while (match(TokenKind.Pipe)) {
			var right = parseBitXor();
			var span = expressionSpan(expression).merge(expressionSpan(right));
			expression = rememberBinary(BitOr(expression, right, span), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitOr, expression, right);
			recordCstNode(SyntaxKind.BinaryExpression, span);
		}
		return expression;
	}

	function parseBitXor():AstExpression {
		var expression = parseBitAnd();
		while (match(TokenKind.Caret)) {
			var right = parseBitAnd();
			var span = expressionSpan(expression).merge(expressionSpan(right));
			expression = rememberBinary(BitXor(expression, right, span), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitXor, expression, right);
			recordCstNode(SyntaxKind.BinaryExpression, span);
		}
		return expression;
	}

	function parseBitAnd():AstExpression {
		var expression = parseShift();
		while (match(TokenKind.Ampersand)) {
			var right = parseShift();
			var span = expressionSpan(expression).merge(expressionSpan(right));
			expression = rememberBinary(BitAnd(expression, right, span), compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitAnd, expression, right);
			recordCstNode(SyntaxKind.BinaryExpression, span);
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
		var result:AstExpression = switch operation {
			case TokenKind.Less: AstExpression.Less(expression, right, span);
			case TokenKind.LessEqual: AstExpression.LessEqual(expression, right, span);
			case TokenKind.Greater: AstExpression.Greater(expression, right, span);
			case TokenKind.GreaterEqual: AstExpression.GreaterEqual(expression, right, span);
			case TokenKind.NotEqual: AstExpression.NotEqual(expression, right, span);
			default: AstExpression.Equal(expression, right, span);
		};
		var binaryOperation = switch operation {
				case TokenKind.Less: compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Less;
				case TokenKind.LessEqual: compiler.syntax.SyntaxTree.SyntaxBinaryOperator.LessEqual;
				case TokenKind.Greater: compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Greater;
				case TokenKind.GreaterEqual: compiler.syntax.SyntaxTree.SyntaxBinaryOperator.GreaterEqual;
				case TokenKind.NotEqual: compiler.syntax.SyntaxTree.SyntaxBinaryOperator.NotEqual;
			default: compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Equal;
		};
			expression = rememberBinary(result, binaryOperation, expression, right);
			recordCstNode(SyntaxKind.BinaryExpression, span);
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
			var result = leftShift ? ShiftLeft(expression, right,
				span) : unsigned ? UnsignedShiftRight(expression, right, span) : ShiftRight(expression, right, span),
				operation = leftShift ? compiler.syntax.SyntaxTree.SyntaxBinaryOperator.ShiftLeft
					: unsigned ? compiler.syntax.SyntaxTree.SyntaxBinaryOperator.UnsignedShiftRight
					: compiler.syntax.SyntaxTree.SyntaxBinaryOperator.ShiftRight;
			expression = rememberBinary(result, operation, expression, right);
			recordCstNode(SyntaxKind.BinaryExpression, span);
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
			expression = rememberBinary(operation == TokenKind.Plus ? Add(expression, right, span) : Sub(expression, right, span),
				operation == TokenKind.Plus ? compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Add : compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Sub,
				expression, right);
			recordCstNode(SyntaxKind.BinaryExpression, span);
		}
		return expression;
	}

	function parseMultiplicative():AstExpression {
		var expression = parsePrimary();
		while (check(TokenKind.Star) || check(TokenKind.Slash) || check(TokenKind.Percent)) {
			var operation = advance().kind,
				right = parsePrimary(),
				span = expressionSpan(expression).merge(expressionSpan(right));
				var result = switch operation {
					case TokenKind.Star: Mul(expression, right, span);
					case TokenKind.Slash: Div(expression, right, span);
					default: Mod(expression, right, span);
				}, binaryOperation = switch operation {
					case TokenKind.Star: compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Mul;
					case TokenKind.Slash: compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Div;
					default: compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Mod;
				};
				expression = rememberBinary(result, binaryOperation, expression, right);
				recordCstNode(SyntaxKind.BinaryExpression, span);
		}
		return expression;
	}

	function parsePrimary():AstExpression {
		if (recovering && isExpressionTerminator(current().kind)) {
			var span = new SourceSpan(current().span.file, current().span.start, current().span.start);
			recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", "Expected expression", span));
			return rememberExpression(ErrorExpression(span), compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Error);
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
			var payload = expressionPayload(value);
			return rememberExpression(ThrowExpression(value, start.merge(expressionSpan(value))),
				payload == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Throw(payload));
		}
		if (check(TokenKind.Identifier) && current().text == "cast") {
			var start = advance().span;
			if (match(TokenKind.LeftParen)) {
				var value = parseExpression(), target:Null<AstType> = null,
					targetPayload:Null<compiler.syntax.SyntaxTree.SyntaxTypePayload> = null;
				if (match(TokenKind.Comma)) {
					var parsedTarget = parseTypeResult();
					target = parsedTarget.ast;
					targetPayload = parsedTarget.payload;
				}
				var end = consume(TokenKind.RightParen).span;
				var valuePayload = expressionPayload(value),
					payload = valuePayload == null ? null
						: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Cast(valuePayload, targetPayload);
				return parsePostfix(rememberExpression(Cast(value, target, start.merge(end)), payload));
			}
			var value = parsePrimary();
			var valuePayload = expressionPayload(value);
			return rememberExpression(Cast(value, null, start.merge(expressionSpan(value))),
				valuePayload == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Cast(valuePayload, null));
		}
		if (match(TokenKind.Function)) {
			var start = previous().span;
			var parameterStart = consume(TokenKind.LeftParen).span;
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
			var parameterEnd = consume(TokenKind.RightParen).span;
			recordCstNode(SyntaxKind.ParameterList, parameterStart.merge(parameterEnd));
			var body = parseAnonymousFunctionBody(),
				end = body.length == 0 ? previous().span : statementSpan(body[body.length - 1]);
			var lambda = Lambda(arguments, body, start.merge(end));
			return rememberExpression(lambda, parserLambdaPayload(arguments, body));
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
			var lambda = Lambda(arguments, body, start.merge(body.length == 0 ? previous().span : statementSpan(body[body.length - 1])));
			return rememberExpression(lambda, parserLambdaPayload(arguments, body));
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
			var conditionPayload = expressionPayload(condition), truePayload = expressionPayload(whenTrue), falsePayload = expressionPayload(whenFalse),
				payload = conditionPayload == null || truePayload == null || falsePayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Conditional(conditionPayload, truePayload, falsePayload);
			return rememberExpression(Conditional(condition, whenTrue, whenFalse, start.merge(expressionSpan(whenFalse))), payload);
		}
		if (match(TokenKind.Minus)) {
			var start = previous().span;
			if (match(TokenKind.Integer)) {
				var token = previous(), value = parseIntegerToken(token, true);
				return parsePostfix(rememberExpression(IntegerLiteral(value, start.merge(token.span)),
					compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Integer(value)));
			}
			var value = parsePrimary();
			return rememberUnary(Negate(value, start.merge(expressionSpan(value))),
				compiler.syntax.SyntaxTree.SyntaxUnaryOperator.Negate, value);
		}
		if (match(TokenKind.Not)) {
			var start = previous().span, value = parsePrimary();
			return rememberUnary(Not(value, start.merge(expressionSpan(value))),
				compiler.syntax.SyntaxTree.SyntaxUnaryOperator.Not, value);
		}
		if (match(TokenKind.BitNot)) {
			var start = previous().span, value = parsePrimary(), negated = IntegerLiteral(-1, start),
				result = BitXor(value, negated, start.merge(expressionSpan(value))), valuePayload = expressionPayload(value);
			return rememberExpression(result, valuePayload == null ? null
				: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Binary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitXor,
					valuePayload, compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Integer(-1)));
		}
		if (match(TokenKind.Integer)) {
			var token = previous();
			var value = parseIntegerToken(token);
			return parsePostfix(rememberExpression(IntegerLiteral(value, token.span),
				compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Integer(value)));
		}
		if (match(TokenKind.Float)) {
			var token = previous(), value = Std.parseFloat(token.text);
			return parsePostfix(rememberExpression(FloatLiteral(value, token.span),
				compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Float(value)));
		}
		if (match(TokenKind.StringLiteral)) {
			var parsed = parseStringExpression(previous());
			return parsePostfix(rememberExpression(parsed, switch parsed {
				case StringLiteral(value, _): compiler.syntax.SyntaxTree.SyntaxExpressionPayload.String(value);
				default: null;
			}));
		}
		if (match(TokenKind.RegexLiteral)) {
			var token = previous(),
				delimiter = token.text.lastIndexOf("/"),
				pattern = StringTools.replace(token.text.substring(2, delimiter), "\\/", "/"),
				options = token.text.substring(delimiter + 1);
			var expression:AstExpression = New("EReg", [StringLiteral(pattern, token.span), StringLiteral(options, token.span)], token.span),
				payload = compiler.syntax.SyntaxTree.SyntaxExpressionPayload.New("EReg", [
					compiler.syntax.SyntaxTree.SyntaxExpressionPayload.String(pattern),
					compiler.syntax.SyntaxTree.SyntaxExpressionPayload.String(options)
				]);
			return parsePostfix(rememberExpression(expression, payload));
		}
		if (match(TokenKind.BoolTrue))
			return parsePostfix(rememberExpression(BoolLiteral(true, previous().span),
				compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Bool(true)));
		if (match(TokenKind.BoolFalse))
			return parsePostfix(rememberExpression(BoolLiteral(false, previous().span),
				compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Bool(false)));
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
					recordCstNode(SyntaxKind.MapLiteral, start.merge(end));
					var iterablePayload = expressionPayload(iterable), conditionPayload = condition == null ? null : expressionPayload(condition),
						keyPayload = expressionPayload(value), mapValuePayload = expressionPayload(mapValue),
						payload = iterablePayload == null || condition != null && conditionPayload == null
							|| keyPayload == null || mapValuePayload == null ? null
							: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.MapComprehension(keyName, valueName,
								iterablePayload, conditionPayload, keyPayload, mapValuePayload);
					return parsePostfix(rememberExpression(MapComprehension(keyName, valueName, iterable, condition, value, mapValue, start.merge(end)), payload));
				}
				var end = consume(TokenKind.RightBracket).span;
				recordCstNode(SyntaxKind.ArrayLiteral, start.merge(end));
				var iterablePayload = expressionPayload(iterable), conditionPayload = condition == null ? null : expressionPayload(condition),
					valuePayload = expressionPayload(value),
					payload = iterablePayload == null || condition != null && conditionPayload == null || valuePayload == null ? null
						: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.ArrayComprehension(keyName, valueName,
							iterablePayload, conditionPayload, valuePayload);
				return parsePostfix(rememberExpression(ArrayComprehension(keyName, valueName, iterable, condition, value, start.merge(end)), payload));
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
					recordCstNode(SyntaxKind.MapLiteral, start.merge(end));
					var entryPayloads:Array<compiler.syntax.SyntaxTree.SyntaxMapEntryPayload> = [], entriesValid = true;
					for (entry in entries) {
						var keyPayload = expressionPayload(entry.key), valuePayload = expressionPayload(entry.value);
						if (keyPayload == null || valuePayload == null) {
							entriesValid = false;
							break;
						}
						entryPayloads.push({key: keyPayload, value: valuePayload});
					}
					var payload:Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> = entriesValid
						? compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Map(entryPayloads) : null;
					return parsePostfix(rememberExpression(MapLiteral(entries, start.merge(end)), payload));
				}
				values.push(first);
				while (match(TokenKind.Comma))
					if (!check(TokenKind.RightBracket))
						values.push(parseDelimitedExpression(TokenKind.RightBracket, false));
			}
			var end = consume(TokenKind.RightBracket).span;
			recordCstNode(SyntaxKind.ArrayLiteral, start.merge(end));
			return parsePostfix(rememberExpression(ArrayLiteral(values, start.merge(end)),
				expressionPayloads(values) == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Array(expressionPayloads(values))));
		}
		if (check(TokenKind.Identifier) && current().text == "null") {
			var nullToken = advance();
			return parsePostfix(rememberExpression(NullLiteral(nullToken.span),
				compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NullValue));
		}
		if (match(TokenKind.New)) {
			var start = previous().span;
			if (check(TokenKind.Identifier) && current().text == "List") {
				advance();
				lastTypeArgumentPayloads = [];
				var typeArguments = check(TokenKind.Less) ? parseTypeArguments() : [];
				var typeArgumentPayloads = lastTypeArgumentPayloads.copy();
				if (isRecoveryBoundary()) {
					recordExpected("left parenthesis");
					var missingEnd = current().span;
					var expression:AstExpression = typeArguments.length > 0
						? NewArray(typeArguments[0], IntegerLiteral(0, missingEnd), start.merge(missingEnd))
						: ArrayLiteral([], start.merge(missingEnd));
					var payload:Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> = typeArguments.length > 0 && typeArgumentPayloads.length > 0
						? compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NewArray(typeArgumentPayloads[0], compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Integer(0))
						: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Array([]);
					return parsePostfix(rememberExpression(expression, payload));
				}
				var argumentStart = consume(TokenKind.LeftParen).span;
				var end = consume(TokenKind.RightParen).span;
				recordCstNode(SyntaxKind.ArgumentList, argumentStart.merge(end));
				if (typeArguments.length > 0) {
				if (typeArguments.length != 1)
						fail(previous(), 'List expects 1 type argument, got ${typeArguments.length}');
					return parsePostfix(rememberExpression(NewArray(typeArguments[0], IntegerLiteral(0, end), start.merge(end)),
						compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NewArray(typeArgumentPayloads[0], compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Integer(0))));
				}
				return parsePostfix(rememberExpression(ArrayLiteral([], start.merge(end)),
					compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Array([])));
			}
			if (check(TokenKind.Identifier) && current().text == "Array") {
				advance();
				if (match(TokenKind.LeftParen)) {
					var argumentStart = previous().span,
						end = consume(TokenKind.RightParen).span;
					recordCstNode(SyntaxKind.ArgumentList, argumentStart.merge(end));
					return parsePostfix(rememberExpression(ArrayLiteral([], start.merge(end)),
						compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Array([])));
				}
				if (isRecoveryBoundary()) {
					recordExpected("type arguments or left parenthesis");
					var missingEnd = current().span;
					return parsePostfix(rememberExpression(ArrayLiteral([], start.merge(missingEnd)),
						compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Array([])));
				}
				consume(TokenKind.Less);
				var parsedElement = parseTypeResult(), element = parsedElement.ast;
				consume(TokenKind.Greater);
				if (isRecoveryBoundary()) {
					recordExpected("left parenthesis");
					var missingEnd = current().span;
					return parsePostfix(NewArray(element, ErrorExpression(missingEnd), start.merge(missingEnd)));
				}
				var argumentStart = consume(TokenKind.LeftParen).span;
				var length = parseExpression();
				var end = consume(TokenKind.RightParen).span;
				recordCstNode(SyntaxKind.ArgumentList, argumentStart.merge(end));
				var lengthPayload = expressionPayload(length), payload = lengthPayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NewArray(parsedElement.payload, lengthPayload);
				return parsePostfix(rememberExpression(NewArray(element, length, start.merge(end)), payload));
			}
			if (check(TokenKind.Identifier) && current().text == "Map") {
				advance();
				if (match(TokenKind.LeftParen)) {
					var end = consume(TokenKind.RightParen).span;
					return parsePostfix(rememberExpression(MapLiteral([], start.merge(end)),
						compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Map([])));
				}
				if (isRecoveryBoundary()) {
					recordExpected("type arguments or left parenthesis");
					var missingEnd = current().span;
					return parsePostfix(rememberExpression(MapLiteral([], start.merge(missingEnd)),
						compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Map([])));
				}
				consume(TokenKind.Less);
				var parsedKey = parseTypeResult(), key = parsedKey.ast;
				var parsedValue = if (match(TokenKind.Comma))
					parseTypeResult();
				else if (isRecoveryBoundary() || check(TokenKind.Greater)) {
					recordExpected("comma");
					parsedType(missingType("map value"), compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType);
				} else {
					consume(TokenKind.Comma);
					parseTypeResult();
				};
				var value = parsedValue.ast;
				consume(TokenKind.Greater);
				if (isRecoveryBoundary()) {
					recordExpected("left parenthesis");
					var missingEnd = current().span;
					return parsePostfix(NewMap(key, value, start.merge(missingEnd)));
				}
				var argumentStart = consume(TokenKind.LeftParen).span;
				var end = consume(TokenKind.RightParen).span;
				recordCstNode(SyntaxKind.ArgumentList, argumentStart.merge(end));
				return parsePostfix(rememberExpression(NewMap(key, value, start.merge(end)),
					compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NewMap(parsedKey.payload, parsedValue.payload)));
			}
			var typeName = parseQualifiedName();
			var typeArguments = parseTypeArguments();
			var typeArgumentPayloads = lastTypeArgumentPayloads.copy();
			if (recovering && (recoveringAtEnd() || isDeclarationBoundary(current()))) {
				recordExpected("left parenthesis");
				var end = current().span;
				var expression:AstExpression = typeArguments.length == 0 ? New(typeName, [], start.merge(end))
					: NewGeneric(typeName, typeArguments, [], start.merge(end));
				var payload:Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> = typeArguments.length == 0
					? compiler.syntax.SyntaxTree.SyntaxExpressionPayload.New(typeName, [])
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NewGeneric(typeName, typeArgumentPayloads, []);
				return parsePostfix(rememberExpression(expression, payload));
			}
			var argumentStart = consume(TokenKind.LeftParen).span;
			var arguments = [];
			if (!check(TokenKind.RightParen)) {
				do
					arguments.push(parseDelimitedExpression(TokenKind.RightParen, false)) while (match(TokenKind.Comma));
			}
			var end = consume(TokenKind.RightParen).span;
			recordCstNode(SyntaxKind.ArgumentList, argumentStart.merge(end));
			var argumentPayloads = expressionPayloads(arguments), payload:Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> = null;
			if (argumentPayloads != null)
				payload = typeArguments.length == 0
					? compiler.syntax.SyntaxTree.SyntaxExpressionPayload.New(typeName, argumentPayloads)
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NewGeneric(typeName, typeArgumentPayloads, argumentPayloads);
			var expression:AstExpression = typeArguments.length == 0 ? New(typeName, arguments, start.merge(end))
				: NewGeneric(typeName, typeArguments, arguments, start.merge(end));
			return parsePostfix(rememberExpression(expression, payload));
		}
		if (check(TokenKind.LeftParen)) {
			var saved = position,
				start = current().span,
				isLambda = parenthesizedLambdaAhead();
				if (!isLambda) {
					advance();
					var grouped = parseExpression();
					var end:SourceSpan;
					var targetPayload:Null<compiler.syntax.SyntaxTree.SyntaxTypePayload> = null;
					if (match(TokenKind.Colon)) {
						var parsedTarget = parseTypeResult(), target = parsedTarget.ast;
						targetPayload = parsedTarget.payload;
						end = consume(TokenKind.RightParen).span;
						var groupedPayload = expressionPayload(grouped), castPayload = groupedPayload == null ? null
							: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Cast(groupedPayload, targetPayload);
						grouped = rememberExpression(Cast(grouped, target, start.merge(end)), castPayload);
					} else
						end = consume(TokenKind.RightParen).span;
				recordCstNode(SyntaxKind.ParenthesizedExpression, start.merge(end));
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
			var parameterEnd = consume(TokenKind.RightParen).span;
			if (match(TokenKind.Arrow)) {
				recordCstNode(SyntaxKind.ParameterList, start.merge(parameterEnd));
				var body = parseArrowFunctionBody();
				var lambda = Lambda(arguments, body, start.merge(body.length == 0 ? previous().span : statementSpan(body[body.length - 1])));
				return rememberExpression(lambda, parserLambdaPayload(arguments, body));
			}
			position = saved;
			advance();
			var grouped = parseExpression();
			consume(TokenKind.Colon);
			var parsedTarget = parseTypeResult(), target = parsedTarget.ast, castEnd = consume(TokenKind.RightParen).span;
			recordCstNode(SyntaxKind.ParenthesizedExpression, start.merge(castEnd));
			var groupedPayload = expressionPayload(grouped), castPayload = groupedPayload == null ? null
				: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Cast(groupedPayload, parsedTarget.payload);
			return parsePostfix(rememberExpression(Cast(grouped, target, start.merge(castEnd)), castPayload));
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
				recordCstNode(SyntaxKind.MemberExpression, start.merge(end));
			}
			var expression:AstExpression = rememberExpression(Variable(name, start.merge(end)),
				compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Variable(name));
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
			recordCstNode(SyntaxKind.ObjectLiteral, start.merge(end));
			var fieldPayloads:Array<compiler.syntax.SyntaxTree.SyntaxObjectFieldPayload> = [], fieldsValid = true;
			for (field in fields) {
				var valuePayload = expressionPayload(field.value);
				if (valuePayload == null) {
					fieldsValid = false;
					break;
				}
				fieldPayloads.push({name: field.name, value: valuePayload});
			}
			var payload:Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> = fieldsValid
				? compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Object(fieldPayloads) : null;
			return parsePostfix(rememberExpression(ObjectLiteral(fields, start.merge(end)), payload));
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
				recordCstNode(SyntaxKind.MemberExpression, start.merge(end));
			}
			var expression:AstExpression = rememberExpression(Variable(name, start.merge(end)),
				compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Variable(name));
			if (match(TokenKind.LeftParen)) {
				var argumentStart = previous().span;
				var arguments = [];
				if (!check(TokenKind.RightParen)) {
					do
					arguments.push(parseDelimitedExpression(TokenKind.RightParen, false)) while (match(TokenKind.Comma));
				}
				var end = consume(TokenKind.RightParen).span;
				recordCstNode(SyntaxKind.ArgumentList, argumentStart.merge(end));
				var callSpan = start.merge(end);
				var argumentPayloads = expressionPayloads(arguments), callPayload = argumentPayloads == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Call(name, argumentPayloads);
				expression = rememberExpression(Call(name, arguments, callSpan), callPayload);
				recordCstNode(SyntaxKind.CallExpression, callSpan);
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
		var parsedType = parseTypeResult(), type = parsedType.ast;
		consume(TokenKind.Greater);
		consume(TokenKind.LeftParen);
		var field:Null<String> = null;
		if (kind == OffsetOf) {
			var token = consume(TokenKind.StringLiteral);
			field = decodeString(token.text);
		}
		var end = consume(TokenKind.RightParen).span;
		return parsePostfix(rememberExpression(NativeLayoutQuery(kind, type, field, name.span.merge(end)),
			compiler.syntax.SyntaxTree.SyntaxExpressionPayload.NativeLayoutQuery(syntaxNativeLayoutKind(kind), parsedType.payload, field)));
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
		var iterablePayload = expressionPayload(iterable), conditionPayload = condition == null ? null : expressionPayload(condition),
			valuePayload = expressionPayload(value), payload = iterablePayload == null || condition != null && conditionPayload == null || valuePayload == null ? null
				: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.ArrayComprehension(keyName, valueName, iterablePayload, conditionPayload, valuePayload);
		return rememberExpression(ArrayComprehension(keyName, valueName, iterable, condition, value, start.merge(expressionSpan(value))), payload);
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
						return rememberBlockExpression(statements, result, start.merge(end));
					}
					statements.push(Expression(result, expressionSpan(result)));
					continue;
				}
				var saved = position, candidate = tryParseExpression();
				if (candidate != null && check(TokenKind.RightBrace)) {
					var end = consume(TokenKind.RightBrace).span;
					return rememberBlockExpression(statements, candidate, start.merge(end));
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
			return rememberBlockExpression(trailing.statements, trailing.result, start.merge(end));
		}
		if (recoveringAtEnd()) {
			var span = current().span;
			recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", "Expression block requires a result expression", span));
			return rememberExpression(ErrorExpression(span), compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Error);
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
		var switchExpressionBodyStart = consume(TokenKind.LeftBrace).span;
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
		recordCstNode(SyntaxKind.Block, switchExpressionBodyStart.merge(end));
		var subjectPayload = expressionPayload(subject), casePayloads = switchExpressionCasePayloads(cases),
			fallbackPayload = fallback == null ? null : expressionPayload(fallback),
			payload:Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> = subjectPayload == null || casePayloads == null
				|| fallback != null && fallbackPayload == null ? null
				: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Switch(subjectPayload, casePayloads, fallbackPayload);
		return parsePostfix(rememberExpression(SwitchExpression(subject, cases, fallback, start.merge(end)), payload));
	}

	function switchExpressionCasePayloads(cases:Array<compiler.syntax.Ast.AstSwitchExpressionCase>):Null<Array<compiler.syntax.SyntaxTree.SyntaxSwitchExpressionCasePayload>> {
		var result:Array<compiler.syntax.SyntaxTree.SyntaxSwitchExpressionCasePayload> = [];
		for (entry in cases) {
			var value = expressionPayload(entry.value), guard = entry.guard == null ? null : expressionPayload(entry.guard), loweredResult = expressionPayload(entry.result);
			if (value == null || entry.guard != null && guard == null || loweredResult == null)
				return null;
			result.push({value: value, guard: guard, result: loweredResult});
		}
		return result;
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
		var lambdaPayload = parserLambdaPayload([], body), payload = lambdaPayload == null ? null
			: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.ClosureCall(lambdaPayload, []);
		return parsePostfix(rememberExpression(ClosureCall(lambda, [], start.merge(end)), payload));
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
					return rememberExpression(EmptyExpression(start.merge(current().span)), compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Empty);
				if (atSwitchBranchEnd() && statements.length > 0 && statementTerminates(statements[statements.length - 1])) {
					var end = statementSpan(statements[statements.length - 1]);
					return rememberBlockExpression(statements, Unreachable(end), start.merge(end));
				}
				if (isStatementOnlyStart(current().kind)) {
					appendStatements(statements, parseStatements());
					continue;
				}
				if (check(TokenKind.LeftBrace) && !(peekKind(1) == TokenKind.Identifier && peekKind(2) == TokenKind.Colon)) {
					var result = parseExpressionBranch();
					match(TokenKind.Semicolon);
					if (atSwitchBranchEnd())
						return statements.length == 0 ? result : rememberBlockExpression(statements, result, start.merge(expressionSpan(result)));
					statements.push(Expression(result, expressionSpan(result)));
					continue;
				}
				var saved = position, result = tryParseExpression();
				if (result != null && match(TokenKind.Semicolon)) {
					if (atSwitchBranchEnd())
						return statements.length == 0 ? result : rememberBlockExpression(statements, result, start.merge(expressionSpan(result)));
					position = saved;
					appendStatements(statements, parseStatements());
					continue;
				}
				if (result != null && atSwitchBranchEnd())
					return statements.length == 0 ? result : rememberBlockExpression(statements, result, start.merge(expressionSpan(result)));
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
					return rememberBlockExpression(statements, rememberExpression(ErrorExpression(end), compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Error), start.merge(end));
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
				var argumentStart = previous().span;
				var arguments = [];
				if (!check(TokenKind.RightParen)) {
					do
						arguments.push(parseExpression()) while (match(TokenKind.Comma));
				}
				var end = consume(TokenKind.RightParen).span;
				recordCstNode(SyntaxKind.ArgumentList, argumentStart.merge(end));
				var callSpan = expressionSpan(expression).merge(end);
				var argumentPayloads = expressionPayloads(arguments), payload:Null<compiler.syntax.SyntaxTree.SyntaxExpressionPayload> = null;
				if (argumentPayloads != null)
					payload = switch expression {
						case Variable(name, _): compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Call(name, argumentPayloads);
						default:
							var calleePayload = expressionPayload(expression);
							calleePayload == null ? null : compiler.syntax.SyntaxTree.SyntaxExpressionPayload.ClosureCall(calleePayload, argumentPayloads);
					};
				expression = switch expression {
					case Variable(name, start): Call(name, arguments, callSpan);
					default: ClosureCall(expression, arguments, callSpan);
				};
				expression = rememberExpression(expression, payload);
				recordCstNode(SyntaxKind.CallExpression, callSpan);
				continue;
			}
			if (match(TokenKind.LeftBracket)) {
				var offset = parseExpression(),
					end = consume(TokenKind.RightBracket).span;
				var indexSpan = expressionSpan(expression).merge(end);
				var arrayPayload = expressionPayload(expression), indexPayload = expressionPayload(offset),
					payload = arrayPayload == null || indexPayload == null ? null
						: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Index(arrayPayload, indexPayload);
				expression = rememberExpression(Index(expression, offset, indexSpan), payload);
				recordCstNode(SyntaxKind.IndexExpression, indexSpan);
				continue;
			}
			if (match(TokenKind.Dot)) {
				if (recovering && (isExpressionTerminator(current().kind) || isDeclarationBoundary(current()))) {
					var span = new SourceSpan(current().span.file, current().span.start, current().span.start);
					recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", "Expected member name", span));
					var memberSpan = expressionSpan(expression).merge(span);
					var objectPayload = expressionPayload(expression), payload = objectPayload == null ? null
						: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Member(objectPayload, "");
					expression = rememberExpression(Member(expression, "", memberSpan), payload);
					recordCstNode(SyntaxKind.MemberExpression, memberSpan);
					break;
				}
				var nameToken = consumeName(), name = nameToken.text;
				if (match(TokenKind.LeftParen)) {
					var argumentStart = previous().span;
					var arguments = [];
					if (!check(TokenKind.RightParen)) {
						do
							arguments.push(parseDelimitedExpression(TokenKind.RightParen, false)) while (match(TokenKind.Comma));
					}
					var end = consume(TokenKind.RightParen).span;
					recordCstNode(SyntaxKind.ArgumentList, argumentStart.merge(end));
					var methodSpan = expressionSpan(expression).merge(end);
					var objectPayload = expressionPayload(expression), argumentPayloads = expressionPayloads(arguments),
						payload = objectPayload == null || argumentPayloads == null ? null
							: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.MethodCall(objectPayload, name, argumentPayloads);
					expression = rememberExpression(MethodCall(expression, name, arguments, methodSpan), payload);
					recordCstNode(SyntaxKind.CallExpression, methodSpan);
				} else {
					var memberSpan = expressionSpan(expression).merge(nameToken.span);
					var objectPayload = expressionPayload(expression), payload = objectPayload == null ? null
						: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.Member(objectPayload, name);
					expression = rememberExpression(Member(expression, name, memberSpan), payload);
					recordCstNode(SyntaxKind.MemberExpression, memberSpan);
				}
				continue;
			}
			if (match(TokenKind.Increment) || match(TokenKind.Decrement)) {
				var end = previous().span,
					delta = previous().kind == TokenKind.Increment ? 1 : -1;
				var targetPayload = expressionPayload(expression), payload = targetPayload == null ? null
					: compiler.syntax.SyntaxTree.SyntaxExpressionPayload.PostfixIncrement(targetPayload, delta);
				expression = rememberExpression(PostfixIncrement(expression, delta, expressionSpan(expression).merge(end)), payload);
				break;
			}
			break;
		}
		return expression;
	}

	function parseType():AstType
		return parseTypeResult().ast;

	function parseTypeResult():ParsedType {
		if (match(TokenKind.LeftParen)) {
			var arguments:Array<AstType> = [], argumentPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload> = [];
			if (!check(TokenKind.RightParen)) {
				do {
					var optional = match(TokenKind.Question);
					if (check(TokenKind.Identifier) && peekKind(1) == TokenKind.Colon) {
						advance();
						advance();
					}
					var argument = parseDelimitedTypeResult(TokenKind.RightParen);
					arguments.push(optional ? NullableType(argument.ast) : argument.ast);
					argumentPayloads.push(optional ? compiler.syntax.SyntaxTree.SyntaxTypePayload.NullableType(argument.payload) : argument.payload);
				} while (match(TokenKind.Comma));
			}
			consume(TokenKind.RightParen);
			consume(TokenKind.Arrow);
			var result = parseTypeResult();
			return {
				ast: chainedFunctionType(arguments, result.ast),
				payload: chainedFunctionTypePayload(argumentPayloads, result.payload)
			};
		}
		var atomic = parseAtomicTypeResult();
		if (match(TokenKind.Arrow)) {
			var result = parseTypeResult(), arguments = switch atomic.ast {
				case VoidType: [];
				default: [atomic.ast];
			};
			var argumentPayloads = switch atomic.ast {
				case VoidType: [];
				default: [atomic.payload];
			};
			return {
				ast: chainedFunctionType(arguments, result.ast),
				payload: chainedFunctionTypePayload(argumentPayloads, result.payload)
			};
		}
		return atomic;
	}

	static function chainedFunctionType(arguments:Array<AstType>, result:AstType):AstType
		return switch result {
			case FunctionType(nextArguments, finalResult): FunctionType(arguments.concat(nextArguments), finalResult);
			default: FunctionType(arguments, result);
		};

	static function chainedFunctionTypePayload(arguments:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload>,
			result:compiler.syntax.SyntaxTree.SyntaxTypePayload):compiler.syntax.SyntaxTree.SyntaxTypePayload
		return switch result {
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.FunctionType(nextArguments, finalResult):
				compiler.syntax.SyntaxTree.SyntaxTypePayload.FunctionType(arguments.concat(nextArguments), finalResult);
			default: compiler.syntax.SyntaxTree.SyntaxTypePayload.FunctionType(arguments, result);
		};

	function parseAtomicType():AstType
		return parseAtomicTypeResult().ast;

	function parseAtomicTypeResult():ParsedType {
		if (recovering && (isExpressionTerminator(current().kind) || isDeclarationBoundary(current()))) {
			var span = new SourceSpan(current().span.file, current().span.start, current().span.start);
			recordRecoveryDiagnostic(new compiler.Diagnostic("E0002", "Expected type", span));
			return {ast: ErrorType(span), payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType};
		}
		if (match(TokenKind.LeftBrace)) {
			var anonymousTypeStart = previous().span;
			var fields:Array<compiler.syntax.Ast.AstAnonymousField> = [], fieldPayloads:Array<compiler.syntax.SyntaxTree.SyntaxAnonymousFieldPayload> = [];
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
					var parsedType = parseTypeResult(), type = parsedType.ast;
					fields.push({
						name: name.text,
						type: type,
						optional: optional,
						span: name.span.merge(previous().span)
					});
					fieldPayloads.push({name: name.text, type: parsedType.payload, optional: optional,
						span: name.span.merge(previous().span)});
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
					fieldPayloads.push({name: fieldName, type: compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType, optional: false,
						span: fieldStart.merge(error.diagnostic.span)});
					synchronizeObjectField();
				}
				if (!match(TokenKind.Comma))
					match(TokenKind.Semicolon);
			}
			var anonymousTypeEnd = consume(TokenKind.RightBrace).span;
			recordCstNode(SyntaxKind.AnonymousType, anonymousTypeStart.merge(anonymousTypeEnd));
			return {ast: AnonymousType(fields), payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.AnonymousType(fieldPayloads)};
		}
		if (match(TokenKind.TypeInt))
			return {ast: IntType, payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.IntType};
		if (match(TokenKind.TypeBool))
			return {ast: BoolType, payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.BoolType};
		if (match(TokenKind.TypeFloat))
			return {ast: FloatType, payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.FloatType};
		if (match(TokenKind.TypeString))
			return {ast: StringType, payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.StringType};
		if (match(TokenKind.Void))
			return {ast: VoidType, payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.VoidType};
		if (check(TokenKind.Identifier))
			if (current().text == "Array") {
				advance();
				if (isRecoveryBoundary()) {
					var missing = missingType("type arguments");
					return {ast: ArrayType(missing), payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.ArrayType(compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType)};
				}
				var arrayTypeStart = consume(TokenKind.Less).span;
					var element = parseDelimitedTypeResult(TokenKind.Greater);
				var arrayTypeEnd = consume(TokenKind.Greater).span;
				recordCstNode(SyntaxKind.TypeArgumentList, arrayTypeStart.merge(arrayTypeEnd));
				return {ast: ArrayType(element.ast), payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.ArrayType(element.payload)};
			} else if (current().text == "Map") {
				advance();
				if (isRecoveryBoundary()) {
					var missingSpan = current().span;
					var missing = missingType("type arguments");
					return {ast: MapType(missing, ErrorType(missingSpan)), payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.MapType(
						compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType, compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType)};
				}
				var mapTypeStart = consume(TokenKind.Less).span;
					var key = parseDelimitedTypeResult(TokenKind.Greater);
					var value = if (match(TokenKind.Comma))
						parseDelimitedTypeResult(TokenKind.Greater);
				else if (isRecoveryBoundary() || check(TokenKind.Greater)) {
					recordExpected("comma");
					var missing = missingType("map value");
					parsedType(missing, compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType);
				} else {
					consume(TokenKind.Comma);
					parseTypeResult();
				};
				var mapTypeEnd = consume(TokenKind.Greater).span;
				recordCstNode(SyntaxKind.TypeArgumentList, mapTypeStart.merge(mapTypeEnd));
				return {ast: MapType(key.ast, value.ast), payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.MapType(key.payload, value.payload)};
			} else if (current().text == "Null") {
				advance();
				if (isRecoveryBoundary()) {
					var missing = missingType("type arguments");
					return {ast: NullableType(missing), payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.NullableType(compiler.syntax.SyntaxTree.SyntaxTypePayload.ErrorType)};
				}
				var nullableTypeStart = consume(TokenKind.Less).span;
					var element = parseDelimitedTypeResult(TokenKind.Greater);
				var nullableTypeEnd = consume(TokenKind.Greater).span;
				recordCstNode(SyntaxKind.TypeArgumentList, nullableTypeStart.merge(nullableTypeEnd));
				return {ast: NullableType(element.ast), payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.NullableType(element.payload)};
			}
		var name = parseQualifiedName();
		if (check(TokenKind.Less) && peekKind(1) == TokenKind.StringLiteral) {
			var nativeTypeStart = advance().span;
			var tag = consume(TokenKind.StringLiteral),
				value = decodeString(tag.text);
			var nativeTypeEnd = consume(TokenKind.Greater).span;
			recordCstNode(SyntaxKind.TypeArgumentList, nativeTypeStart.merge(nativeTypeEnd));
			return {ast: NativeAbstractType(name, value), payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.NativeAbstractType(name, value)};
		}
		if (match(TokenKind.Less)) {
			var appliedTypeStart = previous().span;
			var arguments:Array<AstType> = [], argumentPayloads:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload> = [];
			if (!check(TokenKind.Greater) && !recoveringAtEnd()) {
				var first = parseDelimitedTypeResult(TokenKind.Greater);
				arguments.push(first.ast);
				argumentPayloads.push(first.payload);
				while (match(TokenKind.Comma))
					if (!check(TokenKind.Greater) && !recoveringAtEnd()) {
						var next = parseDelimitedTypeResult(TokenKind.Greater);
						arguments.push(next.ast);
						argumentPayloads.push(next.payload);
					}
			}
			var appliedTypeEnd = consume(TokenKind.Greater).span;
			recordCstNode(SyntaxKind.TypeArgumentList, appliedTypeStart.merge(appliedTypeEnd));
			return {ast: AppliedType(name, arguments), payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.AppliedType(name, argumentPayloads)};
		}
		return {ast: NamedType(name), payload: compiler.syntax.SyntaxTree.SyntaxTypePayload.NamedType(name)};
	}

	static function parsedType(ast:AstType, payload:compiler.syntax.SyntaxTree.SyntaxTypePayload):ParsedType
		return {ast: ast, payload: payload};

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
		var blockStart = previous().span;
		var statements = parseStatementBlockBody();
		var blockEnd = consume(TokenKind.RightBrace).span;
		recordCstNode(SyntaxKind.Block, blockStart.merge(blockEnd));
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
		if (cstRecorder != null) {
			cstRecorder.addMissingToken(kind, span, replacement);
			cstRecorder.missing(span);
		}
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
		if (cstRecorder != null)
			cstRecorder.error(diagnostic.span);
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
		if (cstRecorder != null) {
			cstRecorder.addMissingToken(TokenKind.Identifier, span, "<missing>");
			cstRecorder.missing(span);
		}
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
