package compiler.syntax;

import compiler.core.Diagnostic;
import compiler.core.InternalError;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstFieldAccess;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstInterface;
import compiler.syntax.Ast.AstTypeAlias;
import compiler.syntax.Ast.AstEnum;
import compiler.syntax.Ast.AstAbstract;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstImport;
import compiler.syntax.Ast.AstUsing;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.NativeLayoutQueryKind;
import compiler.core.Source.SourceSpan;
import compiler.core.Source.SourceFile;
import compiler.syntax.Token.TokenKind;
import compiler.syntax.TokenTable.TokenId;
import compiler.core.Diagnostic.CompileError;
import haxe.Int64;

typedef RecoveredParse = {
	final program:AstProgram;
	final diagnostics:Array<compiler.core.Diagnostic>;
}

/** The lambda numbering of a declaration, restored when the parser leaves it. */
private typedef LambdaNumbering = {
	final member:String;
	final counts:Array<Map<String, Int>>;
	final path:LambdaPath;
	final paths:Array<LambdaPath>;
}

/**
 * Where the cursor is in the body it is in (`Parser.openLambda`): its steps, outermost first. A call argument's step is kept
 * as its callee and position and spelled, `name(index)`, only when a lambda is named at it, which few arguments are.
 */
private class LambdaPath {
	final steps:Array<String>;

	/** Per step, the argument position it stands for, or -1 for a step kept as it is written. */
	final arguments:Array<Int>;

	public function new(?steps:Array<String>, ?arguments:Array<Int>) {
		this.steps = steps ?? [];
		this.arguments = arguments ?? [];
	}

	public var length(get, never):Int;

	inline function get_length():Int
		return steps.length;

	public function push(step:String):Void {
		steps.push(step);
		arguments.push(-1);
	}

	/** The step of argument `index` of a call of `callee`. */
	public function pushArgument(callee:String, index:Int):Void {
		steps.push(callee);
		arguments.push(index);
	}

	public function pop():Void {
		steps.pop();
		arguments.pop();
	}

	/** Drops the steps past the first `length`. */
	public function truncate(length:Int):Void {
		steps.resize(length);
		arguments.resize(length);
	}

	public function copy():LambdaPath
		return new LambdaPath(steps.copy(), arguments.copy());

	public function step(index:Int):String {
		var position = arguments[index], text = steps[index];
		return position < 0 ? text : text.substring(text.lastIndexOf(".") + 1) + "(" + position + ")";
	}

	/** The steps joined by `/`. */
	public function join():String {
		if (steps.length == 0)
			return "";
		var out = new StringBuf();
		for (index in 0...steps.length) {
			if (index > 0)
				out.add("/");
			out.add(step(index));
		}
		return out.toString();
	}
}

/**
 * Where to resume lambda numbering after a parse is thrown away. The stacks are pushed and popped in turn, so the entries a
 * mark saw are still there when it is rewound to: it keeps each stack with its length and cuts it back, and the count maps'
 * contents come back by undoing the journal. A parse that threw may have left other stacks current, so the mark's come back.
 */
private typedef LambdaMark = {
	final counts:Array<Map<String, Int>>;
	final countsLength:Int;
	final undo:Int;
	final path:LambdaPath;
	final pathLength:Int;
	final paths:Array<LambdaPath>;
	final pathsLength:Int;
}

/** Every lambda count `openLambda` changed, with the value it had (-1: none), so a rewind can undo back to a mark. */
private class LambdaUndo {
	final maps:Array<Map<String, Int>> = [];
	final anchors:Array<String> = [];
	final previous:Array<Int> = [];

	public function new() {}

	public var length(get, never):Int;

	function get_length():Int
		return maps.length;

	public function record(map:Map<String, Int>, anchor:String, before:Int):Void {
		maps.push(map);
		anchors.push(anchor);
		previous.push(before);
	}

	public function undoTo(length:Int):Void {
		var index = maps.length;
		while (index > length) {
			index--;
			var before = previous[index];
			if (before < 0)
				maps[index].remove(anchors[index]);
			else
				maps[index].set(anchors[index], before);
		}
		maps.resize(length);
		anchors.resize(length);
		previous.resize(length);
	}
}

/** What a parser reads: a token table, or the tokens a caller already has. */
abstract ParserTokens(TokenTable) to TokenTable {
	inline function new(table:TokenTable)
		this = table;

	@:from static inline function ofTable(table:TokenTable):ParserTokens
		return new ParserTokens(table);

	@:from static function ofTokens(tokens:Array<Token>):ParserTokens
		return new ParserTokens(TokenTable.ofTokens(tokens));
}

/** Recursive-descent parser for the supported Haxe-compatible source subset. */
class Parser {
	static inline final MAX_RECOVERY_DIAGNOSTICS = 20;

	final tokens:TokenTable;

	/** The source's tokens; ids from it on name `inserted` tokens. */
	final tokenCount:Int;

	/** Tokens recovery inserted, which the source lacks; the table is never changed. */
	final inserted:Array<Token> = [];
	final finalLocals:Map<String, Bool> = [];
	var position:Int = 0;

	/** Braceless `try` bodies being parsed: their last statement may omit the semicolon before `catch`. */
	var tryBodyDepth:Int = 0;

	var recovering:Bool = false;

	/** Case patterns being parsed: inside one, `name = pattern` is a capture rather than an assignment. */
	var patternDepth:Int = 0;

	/** The declaration whose lambdas are being numbered (see `LambdaName`). */
	var lambdaMember:String = "";

	/**
	 * Lambdas seen so far in each body open at the cursor, by anchor (see `openLambda`), outermost first: the declaration, then
	 * each enclosing lambda.
	 */
	var lambdaCounts:Array<Map<String, Int>> = [[]];

	/** Undoes lambda counts on a rewind; shared with the parsers of interpolated expressions, which share the counts. */
	var lambdaUndo = new LambdaUndo();

	/** Where the cursor is in the body it is in: the declarations, assignments and call arguments around it, outermost first. */
	var lambdaPath = new LambdaPath();

	/** `lambdaPath` of each body that encloses the lambda being parsed. */
	var lambdaPaths:Array<LambdaPath> = [];

	var recoveryDiagnostics:Array<compiler.core.Diagnostic> = [];

	public function new(tokens:ParserTokens) {
		this.tokens = tokens;
		tokenCount = this.tokens.length;
	}

	public function parseProgram():AstProgram {
		var packageName:Null<String> = null,
			imports:Array<AstImport> = [],
			importNames:Map<String, Bool> = [],
			usings:Array<AstUsing> = [];
		if (match(TokenKind.Package)) {
			packageName = parseQualifiedName();
			consume(TokenKind.Semicolon);
		}
		while (check(TokenKind.Import) || isUsingKeyword()) {
			// `using pack.Tools;` imports what `import pack.Tools;` does and makes the static functions of its classes extensions.
			if (isUsingKeyword()) {
				var start = spanOf(advance()), path = parseImportPath();
				if (StringTools.endsWith(path, ".*"))
					fail(previous(), "A using names a module or type, not a package");
				usings.push({path: path, span: new SourceSpan(start.file, start.start, endOf(previous()))});
				imports.push({path: path, alias: null});
				consume(TokenKind.Semicolon);
				continue;
			}
			advance();
			var path = parseImportPath();
			var alias:Null<String> = null;
			if (check(TokenKind.Identifier) && textOf(current()) == "as") {
				advance();
				alias = textOf(consume(TokenKind.Identifier));
				if (importNames.exists(alias))
					fail(previous(), 'Duplicate import alias "$alias"');
				importNames.set(alias, true);
			}
			imports.push({path: path, alias: alias});
			consume(TokenKind.Semicolon);
		}
		var functions = [],
			fields:Array<AstField> = [],
			aliases:Array<AstTypeAlias> = [],
			enums:Array<AstEnum> = [],
			abstracts:Array<AstAbstract> = [],
			interfaces:Array<AstInterface> = [],
			classes = [];
		while (!check(TokenKind.Eof)) {
			var declarationStart = position;
			try {
				var metadata = parseMetadata();
				if (isMacroModifier()) {
					skipMacroFunction();
					continue;
				}
				var visibility = match(TokenKind.Private) ? previous() : match(TokenKind.Public) ? previous() : null;
				var externDeclaration = check(TokenKind.Identifier) && textOf(current()) == "extern";
				if (externDeclaration)
					advance();
				if (match(TokenKind.Typedef))
					aliases.push(parseTypeAlias(visibility == null ? spanOf(previous()) : spanOf(visibility),
						visibility != null && kindOf(visibility) == TokenKind.Private, metadata));
				else if (match(TokenKind.Enum)) {
					var start = spanOf(previous());
					if (check(TokenKind.Identifier) && textOf(current()) == "abstract") {
						advance();
						abstracts.push(parseAbstract(start, false, metadata, true));
					} else
						enums.push(parseEnum(start, metadata));
				} else if (check(TokenKind.Interface))
					interfaces.push(parseInterface());
				else if (check(TokenKind.Class) || check(TokenKind.Struct)) {
					var isStruct = check(TokenKind.Struct);
					if (isStruct && externDeclaration)
						fail(current(), "A struct cannot be declared extern");
					classes.push(parseClass(visibility != null && kindOf(visibility) == TokenKind.Private, metadata,
						externDeclaration, isStruct));
				} else if (check(TokenKind.Var) || check(TokenKind.Final)
					|| check(TokenKind.Inline) && (peekKind(1) == TokenKind.Var || peekKind(1) == TokenKind.Final)) {
					// A module-level variable: public unless `private`, as module-level declarations are (a class's field is private).
					if (externDeclaration)
						fail(current(), "A module-level variable cannot be declared extern");
					var start = visibility == null ? spanOf(current()) : spanOf(visibility),
						isPublic = visibility == null || kindOf(visibility) == TokenKind.Public,
						isInline = match(TokenKind.Inline),
						isFinal = match(TokenKind.Final);
					fields.push(parseField(metadata, isPublic, true, isInline, isFinal, start));
				} else if (visibility != null)
					fail(current(), "Top-level visibility modifier is not supported for this declaration");
				else if (check(TokenKind.Identifier) && textOf(current()) == "abstract") {
					var start = spanOf(advance());
					abstracts.push(parseAbstract(start, externDeclaration, metadata));
				} else {
					var inlineFunction = match(TokenKind.Inline);
					functions.push(parseFunction(false, externDeclaration, metadata, inlineFunction));
				}
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
			aliases: aliases,
			enums: enums,
			abstracts: abstracts,
			interfaces: interfaces,
			classes: classes,
			functions: functions,
			fields: fields,
			usings: usings
		};
	}

	/** `using` before a dotted path: Haxe's keyword, an identifier to this lexer, so a variable may still be named `using`. */
	function isUsingKeyword():Bool
		return check(TokenKind.Identifier) && textOf(current()) == "using" && isNameToken(peekKind(1));

	/** Parse a module or package import, including Haxe's trailing `.*`. */
	function parseImportPath():String {
		var path = textOf(consumeName());
		while (match(TokenKind.Dot)) {
			if (match(TokenKind.Star)) {
				path += ".*";
				break;
			}
			path += "." + textOf(consumeName());
		}
		return path;
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
			switch kindAt(index) {
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
			switch kindOf(advance()) {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				default:
			}
		}
	}

	function isTopLevelStart(token:TokenId):Bool
		return switch kindOf(token) {
			case TokenKind.Function, TokenKind.Class, TokenKind.Interface, TokenKind.Enum, TokenKind.Typedef,
				TokenKind.Public, TokenKind.Private, TokenKind.Var, TokenKind.Final,
				TokenKind.At: true;
			case TokenKind.Identifier: textOf(token) == "abstract" || textOf(token) == "extern";
			default: false;
		};

	function parseMetadata():Array<compiler.syntax.Ast.AstMetadata> {
		var result = [];
		while (match(TokenKind.At)) {
			var start = spanOf(previous());
			consume(TokenKind.Colon);
			var name = parseQualifiedName(), arguments = [];
			// Arguments follow the name directly, as in Haxe: with a space, `@:privateAccess (a + b)` is metadata on a parenthesized
			// expression, not metadata with an argument.
			if (check(TokenKind.LeftParen) && startOf(current()) == endOf(previous())) {
				advance();
				if (!check(TokenKind.RightParen))
					do arguments.push(parseExpression()) while (match(TokenKind.Comma));
				var end = spanOf(consume(TokenKind.RightParen));
				result.push({name: name, arguments: arguments, span: start.merge(end)});
			} else
				result.push({name: name, arguments: arguments, span: spanTo(start, previous())});
		}
		return result;
	}

	/** An abstract, or with `isEnum` an enum abstract: the same members, plus its values and `implements`. */
	function parseAbstract(start:SourceSpan, isExtern:Bool = false, ?metadata:Array<compiler.syntax.Ast.AstMetadata>,
			isEnum:Bool = false):AstAbstract {
		var name = textOf(consume(TokenKind.Identifier)),
			typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeParameters = parseTypeParameters(typeConstraints);
		consume(TokenKind.LeftParen);
		var underlying = parseType();
		consume(TokenKind.RightParen);
		var fromTypes = [], toTypes = [], conformances:Array<AstType> = [];
		while (!check(TokenKind.LeftBrace)) {
			if (isEnum && match(TokenKind.Implements)) {
				conformances.push(parseType());
				if (match(TokenKind.Comma)) fail(previous(),
					'Enum abstract "$name": repeat "implements" for each interface');
				continue;
			}
			if (isEnum && match(TokenKind.Colon)) fail(previous(),
				'Enum abstract "$name": use "implements" to declare conformance');
			var conversion = consume(TokenKind.Identifier);
			if (textOf(conversion) != "from" && textOf(conversion) != "to")
				fail(conversion, isEnum ? 'Expected "from", "to" or "implements"' : 'Expected "from" or "to"');
			var conversionType = parseType();
			if (textOf(conversion) == "from")
				fromTypes.push(conversionType);
			else
				toTypes.push(conversionType);
		}
		consume(TokenKind.LeftBrace);
		var methods:Array<AstFunction> = [],
			fields:Array<AstField> = [],
			values:Null<Array<compiler.syntax.Ast.AstEnumAbstractValue>> = isEnum ? [] : null;
		// Haxe assigns omitted values: Int counts up from the previous literal (starting at 0); String uses the value's name.
		var nextImplicitInt:Null<Int> = 0;
		while (!check(TokenKind.RightBrace)) {
			var methodMetadata = parseMetadata(),
				memberStart = spanOf(current());
			var isStatic = false,
				isInline = false,
				isFinal = false,
				isPublic:Null<Bool> = null,
				isExternMember = false;
			while (check(TokenKind.Public) || check(TokenKind.Private) || check(TokenKind.Inline)
				|| check(TokenKind.Static) || check(TokenKind.Final) || isExternModifier()) {
				if (match(TokenKind.Static))
					isStatic = true;
				else if (match(TokenKind.Inline))
					isInline = true;
				else if (match(TokenKind.Final))
					isFinal = true;
				else if (isExternModifier()) {
					isExternMember = true;
					advance();
				} else
					isPublic = kindOf(advance()) == TokenKind.Public;
			}
			if (values != null && !isStatic && isEnumAbstractValue(isFinal)) {
				var value = parseEnumAbstractValue(name, underlying, nextImplicitInt, methodMetadata);
				nextImplicitInt = switch value.value {
					case IntegerLiteral(literal, _): literal + 1;
					default: null;
				};
				values.push(value);
				continue;
			}
			if (!check(TokenKind.Function)) {
				// A property: what it may be is checked with its type (`AbstractProperties`), as Haxe does.
				fields.push(parseField(methodMetadata, isPublic, isStatic, isInline, isFinal, memberStart));
				continue;
			}
			var functionStart = spanOf(consume(TokenKind.Function)),
				methodName = check(TokenKind.New) ? textOf(advance()) : textOf(consume(TokenKind.Identifier));
			methods.push(parseFunctionBody(functionStart, methodName, true, isStatic,
				externBody(isExtern, isExternMember, isInline), methodMetadata, isInline, isPublic));
		}
		var end = spanOf(consume(TokenKind.RightBrace));
		return {
			name: name,
			isExtern: isExtern,
			metadata: metadata == null ? [] : metadata,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			conformances: conformances,
			underlying: underlying,
			fromTypes: fromTypes,
			toTypes: toTypes,
			fields: fields,
			methods: methods,
			values: values,
			span: start.merge(end)
		};
	}

	/**
	 * Whether the enum abstract member ahead, after its modifiers, is a value: a non-static `var` or `final` with no property
	 * accessors (`var name(get, never)` is a property), as Haxe reads it.
	 */
	function isEnumAbstractValue(afterFinal:Bool):Bool {
		if (afterFinal)
			return !check(TokenKind.Function) && peekKind(1) != TokenKind.LeftParen;
		return check(TokenKind.Var) && peekKind(2) != TokenKind.LeftParen;
	}

	/** `var Name = expr;` or `var Name;`, whose value Haxe numbers or names (`implicitEnumAbstractValue`). */
	function parseEnumAbstractValue(abstractName:String, underlying:AstType,
			nextImplicitInt:Null<Int>,
			metadata:Array<compiler.syntax.Ast.AstMetadata>):compiler.syntax.Ast.AstEnumAbstractValue {
		match(TokenKind.Var);
		var valueName = consumeName();
		// A value's type is its abstract, which it may also be written as.
		if (match(TokenKind.Colon)) {
			var written = previous();
			switch parseType() {
				case NamedType(typeName) if (typeName == abstractName):
				default: fail(written, 'Enum abstract value ${textOf(valueName)} has the type $abstractName');
			}
		}
		var value = if (match(TokenKind.Assign)) parseExpression();
		else implicitEnumAbstractValue(underlying, valueName, nextImplicitInt);
		var end = spanOf(consume(TokenKind.Semicolon));
		return {
			name: textOf(valueName),
			metadata: metadata,
			value: value,
			span: spanOf(valueName).merge(end)
		};
	}

	function implicitEnumAbstractValue(underlying:AstType, name:TokenId, nextInt:Null<Int>):AstExpression {
		return switch underlying {
			case IntType if (nextInt != null): IntegerLiteral(nextInt, spanOf(name));
			case IntType:
				fail(name, 'Enum abstract value ${textOf(name)} needs an explicit value after a non-literal value');
				null;
			case StringType: StringLiteral(textOf(name), spanOf(name));
			default:
				fail(name, 'Enum abstract value ${textOf(name)} needs an explicit value for this underlying type');
				null;
		};
	}

	function parseTypeAlias(start:SourceSpan, isPrivate:Bool,
			metadata:Array<compiler.syntax.Ast.AstMetadata>):AstTypeAlias {
		var name = textOf(consume(TokenKind.Identifier)),
			typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeParameters = parseTypeParameters(typeConstraints);
		consume(TokenKind.Assign);
		var type = parseType(), end = spanOf(previous());
		switch type {
			case AnonymousType(_):
				if (match(TokenKind.Semicolon))
					end = spanOf(previous());
			default:
				end = spanOf(consume(TokenKind.Semicolon));
		}
		return {
			name: name,
			metadata: metadata,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			type: type,
			isPrivate: isPrivate,
			span: start.merge(end)
		};
	}

	function parseEnum(start:SourceSpan, metadata:Array<compiler.syntax.Ast.AstMetadata>):AstEnum {
		var name = textOf(consume(TokenKind.Identifier)),
			typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeParameters = parseTypeParameters(typeConstraints),
			cases = [],
			conformances = [],
			methods = [];
		if (match(TokenKind.Colon))
			fail(previous(), 'Enum "$name": use "implements" to declare conformance');
		while (match(TokenKind.Implements)) {
			conformances.push(parseType());
			if (match(TokenKind.Comma)) fail(previous(), 'Enum "$name": repeat "implements" for each interface');
		}
		consume(TokenKind.LeftBrace);
		while (!check(TokenKind.RightBrace)) {
			var caseMetadata = parseMetadata(), isStatic = false, isInline = false, isPublic:Null<Bool> = null;
			while (true) switch kindOf(current()) {
				case TokenKind.Public, TokenKind.Private: isPublic = kindOf(current()) == TokenKind.Public;
					advance();
				case TokenKind.Static: isStatic = true;
					advance();
				case TokenKind.Inline: isInline = true;
					advance();
				default: break;
			}
			if (match(TokenKind.Function)) {
				var functionStart = spanOf(previous()), methodName = textOf(consume(TokenKind.Identifier));
				methods.push(parseFunctionBody(functionStart, methodName, false, isStatic, false, caseMetadata,
					isInline, isPublic));
				continue;
			}
			if (isStatic || isInline || isPublic != null) fail(current(),
				"Enum constructor cannot have method modifiers");
			var caseToken = consumeName(),
				params:Array<compiler.syntax.Ast.AstEnumParameter> = [];
			if (match(TokenKind.LeftParen)) {
				if (!check(TokenKind.RightParen))
					do {
						var optional = match(TokenKind.Question),
							parameterStart = spanOf(current()),
							name:Null<String> = null;
						if (check(TokenKind.Identifier) && peekKind(1) == TokenKind.Colon) {
							name = textOf(advance());
							advance();
						}
						var type = parseType();
						params.push({
							name: name,
							type: type,
							optional: optional,
							span: spanTo(parameterStart, previous())
						});
					} while (match(TokenKind.Comma));
				consume(TokenKind.RightParen);
			}
			cases.push({
				name: textOf(caseToken),
				metadata: caseMetadata,
				params: params,
				span: spanBetween(caseToken, previous())
			});
			consume(TokenKind.Semicolon);
		}
		var end = spanOf(consume(TokenKind.RightBrace));
		return {
			name: name,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			conformances: conformances,
			methods: methods,
			metadata: metadata,
			cases: cases,
			span: start.merge(end)
		};
	}

	function parseQualifiedName():String {
		if (recovering && isExpressionTerminator(kindOf(current()))) {
			var span = new SourceSpan(spanOf(current()).file, startOf(current()), startOf(current()));
			recordRecoveryDiagnostic(new compiler.core.Diagnostic("E0002", "Expected name", span));
			return "";
		}
		var name = textOf(consumeName());
		while (match(TokenKind.Dot)) {
			if (recovering && isExpressionTerminator(kindOf(current()))) {
				var span = new SourceSpan(spanOf(current()).file, startOf(current()), startOf(current()));
				recordRecoveryDiagnostic(new compiler.core.Diagnostic("E0002", "Expected name", span));
				break;
			}
			name += "." + textOf(consumeName());
		}
		return name;
	}

	/** Numbers the lambdas of the declaration `name` from zero; returns the numbering to resume with `leaveLambdaMember`. */
	function enterLambdaMember(name:String):LambdaNumbering {
		var outer:LambdaNumbering = {
			member: lambdaMember,
			counts: lambdaCounts,
			path: lambdaPath,
			paths: lambdaPaths
		};
		lambdaMember = name;
		lambdaCounts = [[]];
		lambdaPath = new LambdaPath();
		lambdaPaths = [];
		return outer;
	}

	function leaveLambdaMember(outer:LambdaNumbering):Void {
		lambdaMember = outer.member;
		lambdaCounts = outer.counts;
		lambdaPath = outer.path;
		lambdaPaths = outer.paths;
	}

	/**
	 * Takes the identity of a lambda whose body is parsed next, in source order; `closeLambda` ends the body. The identity is
	 * `<member>#<anchor>#<ordinal>`: the anchor is where the lambda is written in its body (`lambdaPath`: the variable, field or
	 * local function it is assigned to, the calls it is an argument of, `return`), and the ordinal counts the lambdas before it
	 * with the same anchor. So adding, removing or moving a lambda leaves the names of the lambdas around it alone unless they
	 * share its anchor, and the patch planner checks those groups for renumbering (`PositionalName`). A lambda with no anchor
	 * keeps the plain `<member>#<ordinal>`. A long anchor keeps its last step and a hash of the whole.
	 */
	function openLambda():String {
		var counts = lambdaCounts[lambdaCounts.length - 1],
			anchor = lambdaAnchor(),
			known = counts.get(anchor),
			ordinal = known == null ? 0 : known,
			identity = lambdaMember + "#" + (anchor == "" ? "" : anchor + "#") + ordinal;
		lambdaUndo.record(counts, anchor, known == null ? -1 : ordinal);
		counts.set(anchor, ordinal + 1);
		lambdaCounts.push([]);
		lambdaPaths.push(lambdaPath);
		lambdaPath = new LambdaPath();
		return identity;
	}

	function closeLambda():Void {
		lambdaCounts.pop();
		var outer = lambdaPaths.pop();
		lambdaPath = outer == null ? new LambdaPath() : outer;
	}

	static inline final LAMBDA_ANCHOR_LIMIT:Int = 48;

	function lambdaAnchor():String {
		var anchor = lambdaPath.join();
		if (anchor.length <= LAMBDA_ANCHOR_LIMIT)
			return anchor;
		var hash:Int = cast 0x811C9DC5;
		for (index in 0...anchor.length)
			hash = (hash ^ anchor.charCodeAt(index)) * 16777619;
		return lambdaPath.step(lambdaPath.length - 1) + "~" + StringTools.hex(hash & 0x7FFFFFFF, 8);
	}

	/** Parses an expression written at `step` of the path that anchors lambdas (see `openLambda`). */
	function parseAnchoredExpression(step:String):AstExpression {
		lambdaPath.push(step);
		var expression = parseExpression();
		lambdaPath.pop();
		return expression;
	}

	/** Parses call arguments up to the closing parenthesis, each anchored at its position in a call of `callee`. */
	/** `...`, three dots, as before a rest parameter or a spread argument. */
	function matchEllipsis():Bool {
		if (!(check(TokenKind.Dot) && peekKind(1) == TokenKind.Dot && peekKind(2) == TokenKind.Dot))
			return false;
		advance();
		advance();
		advance();
		return true;
	}

	/** Only a function's last argument may be a rest parameter, as in Haxe. */
	function rejectEarlyRest(arguments:Array<AstArgument>):Void
		for (index in 0...arguments.length - 1)
			switch arguments[index].type {
				case AppliedType("haxe.Rest", _):
					throw new CompileError(new Diagnostic("E0002",
						"Rest should only be used for the last function argument",
						arguments[index].span));
				default:
			}

	/** A rest parameter's type, `...values:T`, is `haxe.Rest<T>`, as in Haxe. */
	static function restType(rest:Bool, type:AstType):AstType
		return rest ? AppliedType("haxe.Rest", [type]) : type;

	function parseCallArguments(callee:String):Array<AstExpression> {
		var arguments:Array<AstExpression> = [];
		if (!check(TokenKind.RightParen)) {
			do {
				// `...values`: an array whose elements a rest parameter receives.
				var spreadStart = current(), spread = matchEllipsis();
				lambdaPath.pushArgument(callee, arguments.length);
				var argument = parseExpression();
				lambdaPath.pop();
				arguments.push(spread ? Spread(argument, spanFrom(spreadStart, expressionSpan(argument))) : argument);
			} while (match(TokenKind.Comma));
		}
		return arguments;
	}

	/** The step an assignment to `target` adds to the lambda path. */
	static function assignedStep(target:AstExpression):String
		return switch target {
			case Variable(name, _): name.substring(name.lastIndexOf(".") + 1) + "=";
			case Member(_, field, _): field + "=";
			default: "[]=";
		};

	/** A rewind point: parsing that is thrown away must not consume lambda numbers. */
	function lambdaMark():LambdaMark
		return {
			counts: lambdaCounts,
			countsLength: lambdaCounts.length,
			undo: lambdaUndo.length,
			path: lambdaPath,
			pathLength: lambdaPath.length,
			paths: lambdaPaths,
			pathsLength: lambdaPaths.length
		};

	/** Restores the numbering at `mark`; the same mark can be rewound to again after reparsing. */
	function rewindLambdas(mark:LambdaMark):Void {
		lambdaUndo.undoTo(mark.undo);
		lambdaCounts = mark.counts;
		lambdaCounts.resize(mark.countsLength);
		lambdaPaths = mark.paths;
		lambdaPaths.resize(mark.pathsLength);
		lambdaPath = mark.path;
		lambdaPath.truncate(mark.pathLength);
	}

	function parseFunction(allowMissingReturn:Bool, isExtern:Bool = false,
			?metadata:Array<compiler.syntax.Ast.AstMetadata>,
			isInline:Bool = false):AstFunction {
		var start = spanOf(consume(TokenKind.Function)),
			name = check(TokenKind.New) ? textOf(advance()) : textOf(consume(TokenKind.Identifier));
		return parseFunctionBody(start, name, allowMissingReturn, false, isExtern, metadata, isInline);
	}

	function parseFunctionBody(start:SourceSpan, name:String, allowMissingReturn:Bool, isStatic:Bool = false,
			isExtern:Bool = false,
			?metadata:Array<compiler.syntax.Ast.AstMetadata>, isInline:Bool = false, ?isPublic:Bool,
			isOverride:Bool = false):AstFunction {
		var outer = enterLambdaMember(name);
		// Error recovery resumes outside this declaration, so the numbering is restored on errors too.
		var parsed:AstFunction;
		try {
			parsed = parseFunctionDeclaration(start, name, allowMissingReturn, isStatic, isExtern, metadata, isInline,
				isPublic, isOverride);
		} catch (error:CompileError) {
			leaveLambdaMember(outer);
			throw error;
		}
		leaveLambdaMember(outer);
		return parsed;
	}

	function parseFunctionDeclaration(start:SourceSpan, name:String, allowMissingReturn:Bool, isStatic:Bool,
			isExtern:Bool,
			metadata:Null<Array<compiler.syntax.Ast.AstMetadata>>, isInline:Bool, isPublic:Null<Bool>,
			isOverride:Bool):AstFunction {
		var typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeParameters = parseTypeParameters(typeConstraints);
		consume(TokenKind.LeftParen);
		var arguments:Array<AstArgument> = [];
		if (!check(TokenKind.RightParen) && !recoveringAtEnd()) {
			do {
				var rest = matchEllipsis(),
					optional = match(TokenKind.Question),
					argumentToken = consume(TokenKind.Identifier);
				var argumentType = restType(rest, match(TokenKind.Colon) ? parseType() : InferredType),
					defaultValue = match(TokenKind.Assign) ? parseExpression() : null;
				arguments.push({
					name: textOf(argumentToken),
					type: argumentType,
					span: spanBetween(argumentToken, previous()),
					optional: optional,
					defaultValue: defaultValue
				});
			} while (match(TokenKind.Comma));
			rejectEarlyRest(arguments);
		}
		consume(TokenKind.RightParen);
		var result = match(TokenKind.Colon) ? parseType() : allowMissingReturn
			&& name == "new" ? VoidType : InferredType;
		var statements = [], end:SourceSpan;
		if (isExtern) {
			end = spanOf(consume(TokenKind.Semicolon));
		} else if (match(TokenKind.LeftBrace)) {
			var bodyStart = position;
			while (!check(TokenKind.RightBrace) && !check(TokenKind.Eof)) {
				var statementStart = position, statementLambdas = lambdaMark();
				try
					parseStatements(statements)
				catch (error:CompileError) {
					if (!recovering)
						throw error;
					rewindLambdas(statementLambdas);
					recordRecoveryDiagnostic(error.diagnostic);
					statements.push(ErrorStatement(error.diagnostic.span));
					synchronizeStatement(bodyStart, statementStart);
				}
			}
			end = spanOf(consume(TokenKind.RightBrace));
		} else if (recoveringAtEnd()) {
			missingFunctionBody();
			end = spanOf(current());
		} else {
			parseStatements(statements);
			end = statementSpan(statements[statements.length - 1]);
		}
		compiler.types.analysis.FinalLocalChecker.check(arguments, statements, finalLocals);
		return {
			name: name,
			isStatic: isStatic,
			isPublic: isPublic,
			isOverride: isOverride,
			// A function with `@:hlNative` is the native, as Haxe compiles it on HashLink: an extern one, whose body (if it has one)
			// is typed but never runs (`ProgramTyper.checkNativeBoundBodies`). Haxeon binds it on Wasm too, as it binds an extern's
			// `@:hlNative` there (the Wasm runtime provides `haxeon_runtime`'s natives).
			isExtern: isExtern || hasMetadataNamed(metadata, "hlNative"),
			isInline: isInline,
			metadata: metadata == null ? [] : metadata,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			arguments: arguments,
			result: result,
			statements: statements,
			span: start.merge(end)
		};
	}

	static function hasMetadataNamed(metadata:Null<Array<compiler.syntax.Ast.AstMetadata>>, name:String):Bool {
		if (metadata != null)
			for (entry in metadata)
				if (entry.name == name)
					return true;
		return false;
	}

	function synchronizeStatement(bodyStart:Int, statementStart:Int):Void {
		var braceDepth = 0;
		for (index in bodyStart...position)
			switch kindAt(index) {
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
			if (braceDepth == 0 && check(TokenKind.RightBrace))
				return;
			var consumed = kindOf(advance());
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

	function parseTypeParameters(?constraints:Array<compiler.syntax.Ast.AstTypeConstraint>):Array<String> {
		var result = [];
		if (!match(TokenKind.Less))
			return result;
		do {
			var parameter = consume(TokenKind.Identifier);
			if (result.indexOf(textOf(parameter)) >= 0)
				fail(parameter, 'Duplicate type parameter "${textOf(parameter)}"');
			result.push(textOf(parameter));
			// `T:Measured`, `T:Readable & Writable` (Haxe 4's spelling of several constraints) or `T:(Readable, Writable)`.
			if (match(TokenKind.Colon)) {
				var grouped = match(TokenKind.LeftParen);
				do {
					var constraint = parseType();
					if (constraints != null)
						constraints.push({
							parameter: textOf(parameter),
							type: constraint,
							span: spanBetween(parameter, previous())
						});
				} while (grouped ? match(TokenKind.Comma) : match(TokenKind.Ampersand));
				if (grouped)
					consume(TokenKind.RightParen);
			}
		} while (match(TokenKind.Comma));
		consume(TokenKind.Greater);
		return result;
	}

	function parseTypeArguments():Array<AstType> {
		var result = [];
		if (!match(TokenKind.Less))
			return result;
		do result.push(parseType()) while (match(TokenKind.Comma));
		consume(TokenKind.Greater);
		return result;
	}

	function parseClass(isPrivate:Bool, metadata:Array<compiler.syntax.Ast.AstMetadata>, isExtern:Bool = false,
			isStruct:Bool = false):AstClass {
		var start = spanOf(consume(isStruct ? TokenKind.Struct : TokenKind.Class)),
			name = textOf(consume(TokenKind.Identifier)),
			typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeParameters = parseTypeParameters(typeConstraints),
			base:Null<AstType> = null,
			interfaces = [];
		if (isStruct && match(TokenKind.Extends))
			fail(previous(), 'Struct "$name" cannot extend a class; use "implements" to declare interface conformance');
		if (!isStruct && match(TokenKind.Extends)) base = parseType();
		if (isStruct && match(TokenKind.Colon))
			fail(previous(), 'Struct "$name": use "implements" to declare conformance');
		while (match(TokenKind.Implements)) {
			interfaces.push(parseType());
			if (match(TokenKind.Comma)) fail(previous(), 'Type "$name": repeat "implements" for each interface');
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
				// Haxe's position of a field starts at its first modifier, after its metadata.
				var modifierStart = spanOf(current());
				var isStatic = false, isInline = false, isFinal = false, isOverride = false, isExternMember = false;
				var isPublic:Null<Bool> = null;
				while (true) {
					if (kindOf(current()) == TokenKind.Identifier && textOf(current()) == "override") {
						isOverride = true;
						advance();
						continue;
					}
					if (isExternModifier()) {
						isExternMember = true;
						advance();
						continue;
					}
					switch kindOf(current()) {
						case TokenKind.Public, TokenKind.Private:
							isPublic = kindOf(current()) == TokenKind.Public;
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
				}
				if (match(TokenKind.Function)) {
					var functionStart = spanOf(previous()),
						methodName = check(TokenKind.New) ? textOf(advance()) : textOf(consume(TokenKind.Identifier));
					methods.push(parseFunctionBody(functionStart, methodName, true, isStatic,
						externBody(isExtern, isExternMember, isInline), memberMetadata, isInline, isPublic,
						isOverride));
				} else
					fields.push(parseField(memberMetadata, isPublic, isStatic, isInline, isFinal, null, modifierStart));
			} catch (error:CompileError) {
				if (!recovering)
					throw error;
				recordRecoveryDiagnostic(error.diagnostic);
				synchronizeClassMember(bodyStart, memberStart);
			}
		}
		var end = spanOf(consume(TokenKind.RightBrace));
		return {
			name: name,
			isStruct: isStruct,
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

	/**
	 * A field after its modifiers, of a class or of the module: `var` (optional after `final`), the name, `(get, set)`, the type
	 * and the initializer, at least one of the last two.
	 */
	function parseField(memberMetadata:Array<compiler.syntax.Ast.AstMetadata>, isPublic:Null<Bool>, isStatic:Bool,
			isInline:Bool, isFinal:Bool, ?start:SourceSpan, ?declarationStart:SourceSpan):AstField {
		var fieldStart = start == null ? spanOf(current()) : start;
		match(TokenKind.Var);
		var fieldName = textOf(consume(TokenKind.Identifier));
		var readAccess = null, writeAccess = null;
		if (match(TokenKind.LeftParen)) {
			readAccess = parseFieldAccess();
			consume(TokenKind.Comma);
			writeAccess = parseFieldAccess();
			consume(TokenKind.RightParen);
		}
		var fieldType = match(TokenKind.Colon) ? parseType() : null,
			outerMember = enterLambdaMember(fieldName);
		var initializer:Null<AstExpression> = null;
		try {
			if (match(TokenKind.Assign))
				initializer = parseExpression();
		} catch (error:CompileError) {
			leaveLambdaMember(outerMember);
			throw error;
		}
		leaveLambdaMember(outerMember);
		if (fieldType == null) {
			if (initializer == null)
				fail(current(), 'Field "$fieldName" requires a type or initializer');
		}
		// Like local declarations, a braced initializer (block or switch) may omit the trailing semicolon.
		var end = initializer == null ? spanOf(consume(TokenKind.Semicolon)) : expressionEnd(initializer);
		return {
			name: fieldName,
			isPublic: isPublic,
			metadata: memberMetadata,
			type: fieldType,
			initializer: initializer,
			readAccess: readAccess,
			writeAccess: writeAccess,
			isStatic: isStatic,
			isInline: isInline,
			isFinal: isFinal,
			span: fieldStart.merge(end),
			declarationSpan: declarationStart == null ? null : declarationStart.merge(end)
		};
	}

	/** `extern` among a member's modifiers. */
	inline function isExternModifier():Bool
		return kindOf(current()) == TokenKind.Identifier && textOf(current()) == "extern";

	/**
	 * Whether a method has no body: every method of an extern type, and, as in Haxe, an `extern` member that is not inline (a
	 * native, `@:hlNative(...) static extern function f():Int;`). An `extern inline` member has a body, which is always inlined.
	 */
	static function externBody(externType:Bool, externMember:Bool, isInline:Bool):Bool
		return externType || externMember && !isInline;

	inline function isMacroModifier():Bool
		return check(TokenKind.Identifier) && textOf(current()) == "macro";

	/** Macro declarations are compile-time only; retain their source tokens but omit them from the runtime AST. */
	function skipMacroFunction():Void {
		advance();
		while (check(TokenKind.Public) || check(TokenKind.Private) || check(TokenKind.Static) || check(TokenKind.Inline)
			|| check(TokenKind.Final))
			advance();
		if (!match(TokenKind.Function))
			fail(current(), "Macro modifier requires a function declaration");
		var parentheses = 0, brackets = 0, bodyDepth = 0;
		while (!check(TokenKind.Eof)) {
			var token = advance();
			switch kindOf(token) {
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
						switch kindOf(advance()) {
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
			switch kindAt(index) {
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
			switch kindOf(advance()) {
				case TokenKind.LeftBrace:
					braceDepth++;
				case TokenKind.RightBrace:
					if (braceDepth > 0)
						braceDepth--;
				default:
			}
		}
	}

	function isClassMemberStart(token:TokenId):Bool
		return switch kindOf(token) {
			case TokenKind.Function, TokenKind.Var, TokenKind.Public, TokenKind.Private, TokenKind.Static,
				TokenKind.Inline, TokenKind.Final, TokenKind.At,
				TokenKind.Identifier: true;
			default: false;
		};

	function parseFieldAccess():AstFieldAccess {
		var token = advance();
		var access:Null<AstFieldAccess> = switch textOf(token) {
			case "null": NullAccess;
			case "default": DefaultAccess;
			case "never": NeverAccess;
			case "get": GetAccess;
			case "set": SetAccess;
			case "dynamic": DynamicAccess;
			default: null;
		};
		if (access == null)
			fail(token, 'Unknown property access mode "${textOf(token)}"');
		return access;
	}

	function parseInterface():AstInterface {
		var start = spanOf(consume(TokenKind.Interface)),
			name = textOf(consume(TokenKind.Identifier)),
			typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
			typeParameters = parseTypeParameters(typeConstraints),
			bases = [];
		if (match(TokenKind.Extends)) {
			bases.push(parseType());
			while (match(TokenKind.Comma))
				bases.push(parseType());
		}
		consume(TokenKind.LeftBrace);
		var methods:Array<AstFunction> = [], fields:Array<AstField> = [];
		while (!check(TokenKind.RightBrace)) {
			var methodMetadata = parseMetadata(),
				memberStart = spanOf(current()),
				isPublic:Null<Bool> = null,
				isStatic = false,
				isFinal = false;
			while (check(TokenKind.Public) || check(TokenKind.Private) || check(TokenKind.Static)
				|| check(TokenKind.Inline) || check(TokenKind.Final)) {
				if (check(TokenKind.Public) || check(TokenKind.Private))
					isPublic = kindOf(current()) == TokenKind.Public;
				else if (check(TokenKind.Static))
					isStatic = true;
				else if (check(TokenKind.Final))
					isFinal = true;
				advance();
			}
			// A variable or property: what it may be is checked with the interface (`InterfaceProperties`), as Haxe does.
			if (check(TokenKind.Var) || isFinal) {
				fields.push(parseField(methodMetadata, isPublic, isStatic, false, isFinal, null, memberStart));
				continue;
			}
			var methodStart = spanOf(consume(TokenKind.Function)),
				methodName = textOf(consume(TokenKind.Identifier));
			var typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint> = [],
				typeParameters = parseTypeParameters(typeConstraints);
			consume(TokenKind.LeftParen);
			var arguments:Array<AstArgument> = [];
			if (!check(TokenKind.RightParen))
				do {
					var rest = matchEllipsis(),
						optional = match(TokenKind.Question),
						argumentName = textOf(consume(TokenKind.Identifier));
					consume(TokenKind.Colon);
					var type = restType(rest, parseType()),
						span = spanOf(previous()),
						defaultValue = match(TokenKind.Assign) ? parseExpression() : null;
					arguments.push({
						name: argumentName,
						type: type,
						span: span,
						optional: optional,
						defaultValue: defaultValue
					});
				} while (match(TokenKind.Comma));
			rejectEarlyRest(arguments);
			consume(TokenKind.RightParen);
			var result = match(TokenKind.Colon) ? parseType() : failType("Interface methods require a return type"),
				end = spanOf(consume(TokenKind.Semicolon));
			methods.push({
				name: methodName,
				isStatic: false,
				isPublic: true,
				isExtern: false,
				isInline: false,
				metadata: methodMetadata,
				typeParameters: typeParameters,
				typeConstraints: typeConstraints,
				arguments: arguments,
				result: result,
				statements: [],
				span: methodStart.merge(end)
			});
		}
		var end = spanOf(consume(TokenKind.RightBrace));
		return {
			name: name,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			bases: bases,
			fields: fields,
			methods: methods,
			span: start.merge(end)
		};
	}

	/** What `entry` on a statement or expression changes about checking it, or null for metadata the typer ignores there. */
	static function scopeMetadata(entry:compiler.syntax.Ast.AstMetadata):Null<compiler.syntax.Ast.ScopeMetadata>
		return switch entry.name {
			case "privateAccess": PrivateAccess;
			case "nullSafety" if (entry.arguments.length == 1
				&& entry.arguments[0].match(Variable("Off", _))): NullSafetyOff;
			default: null;
		};

	function parseStatement():AstStatement {
		if (check(TokenKind.At)) {
			var metadata = parseMetadata(), statement = parseStatement();
			for (entry in metadata) {
				var scoped = scopeMetadata(entry);
				if (scoped != null)
					statement = AnnotatedStatement(scoped, statement, entry.span.merge(statementSpan(statement)));
			}
			return statement;
		}
		if (check(TokenKind.Identifier) && textOf(current()) == "scoped" && peekKind(1) == TokenKind.Var) {
			var start = spanOf(advance());
			consume(TokenKind.Var);
			var name = textOf(consume(TokenKind.Identifier));
			var type = match(TokenKind.Colon) ? parseType() : null;
			consume(TokenKind.Assign);
			var initializer = parseAnchoredExpression(name + "=");
			return ScopedDeclaration(name, type, initializer, start.merge(expressionEnd(initializer)));
		}
		// A local `inline function` is replaced by its body at each call and makes no closure (`LocalInlineFunctions`).
		var inlined = check(TokenKind.Inline) && peekKind(1) == TokenKind.Function;
		if (inlined)
			advance();
		if (match(TokenKind.Function)) {
			var start = inlined ? spanOf(ahead(-2)) : spanOf(previous()),
				name = textOf(consume(TokenKind.Identifier));
			// A local function is anchored at its name.
			lambdaPath.push(name);
			var identity = openLambda();
			lambdaPaths[lambdaPaths.length - 1].pop();
			consume(TokenKind.LeftParen);
			var arguments:Array<AstArgument> = [];
			if (!check(TokenKind.RightParen))
				do {
					var rest = matchEllipsis(),
						optional = match(TokenKind.Question),
						argument = consume(TokenKind.Identifier),
						type = restType(rest, match(TokenKind.Colon) ? parseType() : InferredType),
						defaultValue = match(TokenKind.Assign) ? parseExpression() : null;
					arguments.push({
						name: textOf(argument),
						type: type,
						span: spanBetween(argument, previous()),
						optional: optional,
						defaultValue: defaultValue
					});
				} while (match(TokenKind.Comma));
			rejectEarlyRest(arguments);
			consume(TokenKind.RightParen);
			var result = match(TokenKind.Colon) ? parseType() : null,
				body = parseStatementOrBlock(),
				end = body.length == 0 ? spanOf(previous()) : statementSpan(body[body.length - 1]),
				span = start.merge(end),
				declared = result == null ? null : localFunctionType(arguments, result);
			closeLambda();
			return VarDeclaration(name, declared, Lambda(arguments, body, identity, span, inlined, true), span);
		}
		if (match(TokenKind.Defer)) {
			var start = spanOf(previous());
			var body = parseStatementOrBlock();
			return Defer(body, start.merge(statementEnd(body)));
		}
		if (match(TokenKind.Break)) {
			var start = spanOf(previous());
			return Break(spanTo(start, consume(TokenKind.Semicolon)));
		}
		if (match(TokenKind.Continue)) {
			var start = spanOf(previous());
			return Continue(spanTo(start, consume(TokenKind.Semicolon)));
		}
		if (match(TokenKind.Var)) {
			var start = spanOf(previous());
			var name = textOf(consume(TokenKind.Identifier));
			var type = match(TokenKind.Colon) ? parseType() : null;
			consume(TokenKind.Assign);
			var initializer = parseAnchoredExpression(name + "=");
			var end = expressionEnd(initializer);
			return VarDeclaration(name, type, initializer, start.merge(end));
		}
		if (match(TokenKind.Return)) {
			var start = spanOf(previous());
			if (check(TokenKind.Semicolon))
				return ReturnVoid(spanTo(start, consume(TokenKind.Semicolon)));
			var expression = parseAnchoredExpression("return");
			var end = expressionEnd(expression);
			return Return(expression, start.merge(end));
		}
		if (match(TokenKind.Throw)) {
			var start = spanOf(previous()),
				expression = parseExpression(),
				end = expressionEnd(expression);
			return Throw(expression, start.merge(end));
		}
		if (match(TokenKind.Try)) {
			var start = spanOf(previous()),
				tryBranch = parseTryBody(),
				catches:Array<compiler.syntax.Ast.AstCatch> = [],
				end = spanOf(previous());
			do {
				var catchStart = spanOf(consume(TokenKind.Catch));
				consume(TokenKind.LeftParen);
				var catchName = textOf(consume(TokenKind.Identifier));
				// As in Haxe, `catch (e)` with no type catches everything.
				var catchType = match(TokenKind.Colon) ? parseType() : NamedType("Dynamic");
				consume(TokenKind.RightParen);
				var catchBranch = parseTryBody();
				end = catchBranch.length == 0 ? spanOf(previous()) : statementSpan(catchBranch[catchBranch.length - 1]);
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
			var start = spanOf(previous());
			// A parenthesized subject is an ordinary grouped expression, which
			// also covers a type check such as `switch (value : Kind)`.
			var expression = parseExpression();
			consume(TokenKind.LeftBrace);
			var cases = [];
			while (match(TokenKind.Case)) {
				var caseStart = spanOf(previous()),
					values = parseCasePatterns();
				var guard = parseSwitchGuard();
				consume(TokenKind.Colon);
				var statements = [];
				while (!check(TokenKind.RightBrace) && !check(TokenKind.Case) && !check(TokenKind.Default)
					&& !check(TokenKind.Eof))
					parseStatements(statements);
				var caseEnd = statements.length == 0
					? expressionSpan(values[values.length - 1]) : statementSpan(statements[statements.length - 1]);
				cases.push({
					patterns: values,
					guard: guard,
					statements: statements,
					span: caseStart.merge(caseEnd)
				});
			}
			var defaultBranch = [], hasDefault = match(TokenKind.Default);
			if (hasDefault) {
				consume(TokenKind.Colon);
				while (!check(TokenKind.RightBrace) && !check(TokenKind.Eof))
					parseStatements(defaultBranch);
			}
			var end = spanOf(consume(TokenKind.RightBrace));
			if (match(TokenKind.Semicolon))
				end = spanOf(previous());
			return Switch(expression, cases, defaultBranch, hasDefault, start.merge(end));
		}
		if (check(TokenKind.Identifier) || check(TokenKind.This)) {
			var saved = position,
				savedLambdas = lambdaMark(),
				target = parseOr();
			if (match(TokenKind.Increment) || match(TokenKind.Decrement)) {
				var delta = kindOf(previous()) == TokenKind.Increment ? 1 : -1,
					end = spanOf(consume(TokenKind.Semicolon));
				return switch target {
					case Variable(name, _):
						Increment(name, delta, expressionSpan(target).merge(end));
					default: throw new CompileError(new Diagnostic("E0002", "Increment target must be a variable",
						expressionSpan(target)));
				};
			}
			// `<<=`, `>>=` and `>>>=` arrive as separate adjacent tokens, like the shifts themselves.
			var shiftKind = shiftAssignmentKind();
			if (shiftKind > 0) {
				advance();
				advance();
				if (shiftKind == 10 || shiftKind == 11)
					advance();
				if (shiftKind == 11)
					advance();
			}
			var assignmentKind = shiftKind > 0 ? shiftKind : match(TokenKind.Assign) ? 0 : match(TokenKind.PlusAssign)
				? 1 : match(TokenKind.MinusAssign) ? 2 : match(TokenKind.StarAssign) ? 3 : match(TokenKind.SlashAssign)
				? 4 : match(TokenKind.PercentAssign) ? 5 : match(TokenKind.AndAssign) ? 6 : match(TokenKind.OrAssign)
				? 7 : match(TokenKind.XorAssign) ? 8 : -1;
			if (assignmentKind >= 0) {
				var value = parseAnchoredExpression(assignedStep(target)), end = expressionEnd(value);
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
						case 9: ShiftLeft(target, value, operationSpan);
						case 10: ShiftRight(target, value, operationSpan);
						case 11: UnsignedShiftRight(target, value, operationSpan);
						default: BitXor(target, value, operationSpan);
					},
						assignment = switch target {
					case Variable(name, _): Assignment(name, assigned, expressionSpan(target).merge(end));
					case Index(array, offset, _): IndexAssignment(array, offset, assigned,
						expressionSpan(target).merge(end));
					case Member(object, field, _): FieldAssignment(object, field, assigned,
						expressionSpan(target).merge(end));
					default:
						throw new CompileError(new Diagnostic("E0002",
							"Assignment target must be a variable, field, or array element",
							expressionSpan(target)));
				};
				if (bindings.length == 0)
					return assignment;
				bindings.push(assignment);
				return Expression(BlockExpression(bindings, IntegerLiteral(0, span), span), span);
			}
			position = saved;
			rewindLambdas(savedLambdas);
		}
		// A bare block in statement position is a nested scope. Its value, if it
		// ends in one, would be discarded, so it parses once, as statements, and
		// need not end in a value (`{ var x = f(); for (...) g(x); }`). It lowers
		// to `if (true) { ... }`: branches already open a scope and pass
		// break, continue and return through, so no pass needs a block form.
		// `{name: ...}` and `{"name": ...}` stay object literals.
		if (check(TokenKind.LeftBrace)
			&& !((peekKind(1) == TokenKind.Identifier || peekKind(1) == TokenKind.StringLiteral)
			&& peekKind(2) == TokenKind.Colon)) {
			var start = spanOf(current()),
				statements = parseStatementOrBlock(),
				span = spanTo(start, previous());
			match(TokenKind.Semicolon);
			return If(BoolLiteral(true, start), statements, [], span);
		}
		if (match(TokenKind.If)) {
			var start = spanOf(previous());
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
			var start = spanOf(previous());
			consume(TokenKind.LeftParen);
			var condition = parseExpression();
			consume(TokenKind.RightParen);
			var body = parseStatementOrBlock();
			var end = statementEnd(body);
			return While(condition, body, start.merge(end));
		}
		if (match(TokenKind.Do)) {
			var start = spanOf(previous()), body = parseDoWhileBody();
			consume(TokenKind.While);
			consume(TokenKind.LeftParen);
			var condition = parseExpression();
			consume(TokenKind.RightParen);
			var end = spanOf(consume(TokenKind.Semicolon));
			return DoWhile(body, condition, start.merge(end));
		}
		if (match(TokenKind.For)) {
			var start = spanOf(previous());
			consume(TokenKind.LeftParen);
			match(TokenKind.Var);
			var name = textOf(consume(TokenKind.Identifier)), valueName = null;
			if (match(TokenKind.Assign)) {
				consume(TokenKind.Greater);
				valueName = textOf(consume(TokenKind.Identifier));
			}
			consume(TokenKind.In);
			var iterable = parseExpression();
			consume(TokenKind.RightParen);
			var body = parseStatementOrBlock(), end = statementEnd(body);
			return ForIn(name, valueName, iterable, body, start.merge(end));
		}
		var expression = parseExpression(), end = expressionEnd(expression);
		return Expression(expression, expressionSpan(expression).merge(end));
	}

	/** The body of a `try` or of one of its `catch`es. */
	function parseTryBody():Array<AstStatement> {
		if (check(TokenKind.LeftBrace))
			return parseStatementOrBlock();
		// Any single statement (`try return f() catch ...`, `catch (e:E) throw e catch ...`); as in Haxe, the semicolon before a
		// following `catch` is optional.
		tryBodyDepth++;
		try {
			var statements = [];
			parseStatements(statements);
			tryBodyDepth--;
			return statements;
		} catch (error:CompileError) {
			tryBodyDepth--;
			throw error;
		}
	}

	function parseDoWhileBody():Array<AstStatement> {
		if (check(TokenKind.LeftBrace))
			return parseStatementOrBlock();
		var expression = parseExpression();
		match(TokenKind.Semicolon);
		return [Expression(expression, expressionSpan(expression))];
	}

	/** The function type a local function or a lambda with a declared result exposes: its parameters' types and optional flags. */
	static function localFunctionType(arguments:Array<AstArgument>, result:AstType):AstType
		return FunctionType([for (argument in arguments) localParameterType(argument)], result,
			[for (argument in arguments) AstPredicates.isOptionalArgument(argument)]);

	/** The parameter type a local function exposes: nullable by Haxe's rule (`AstPredicates.isNullableArgument`), as for declared functions. */
	public static function localParameterType(argument:AstArgument):AstType {
		if (!AstPredicates.isNullableArgument(argument))
			return argument.type;
		return switch argument.type {
			case InferredType, NullableType(_): argument.type;
			default: NullableType(argument.type);
		};
	}

	function parseAnonymousFunctionBody():Array<AstStatement> {
		if (check(TokenKind.LeftBrace))
			return parseStatementOrBlock();
		var start = spanOf(current());
		match(TokenKind.Return);
		var value = parseExpression();
		// The terminator belongs to the surrounding expression statement. If
		// this blockless closure is assigned, consuming it here makes the outer
		// parser see the following statement where it still expects a semicolon.
		return [Return(value, start.merge(expressionSpan(value)))];
	}

	function parseArrowFunctionBody():Array<AstStatement> {
		if (check(TokenKind.LeftBrace)) {
			var statements = parseStatementOrBlock();
			// As in Haxe, the value of an arrow function's block is its last expression. A callback that is expected
			// to return nothing discards it, as it does the value of an expression body.
			returnArrowValue(statements);
			return statements;
		}
		// A loop body is the loop, which has no value, as in Haxe (where a loop is an expression of type Void): `() -> for (x in xs) f(x)`.
		if (check(TokenKind.For) || check(TokenKind.While) || check(TokenKind.Do))
			return [parseStatement()];
		// So is an `if` without an `else`, which Haxe types Void: `x -> if (x > 0) f(x)`.
		if (check(TokenKind.If) && !ifHasElseAhead())
			return [parseVoidIf()];
		var value = parseExpression();
		return [Return(value, expressionSpan(value))];
	}

	/** An `if` without an `else` in an expression's place, as Haxe reads it: a statement whose branch ends with the expression. */
	function parseVoidIf():AstStatement {
		var start = spanOf(advance());
		consume(TokenKind.LeftParen);
		var condition = parseExpression();
		consume(TokenKind.RightParen);
		var thenBranch = if (check(TokenKind.LeftBrace))
			parseStatementOrBlock()
			else if (check(TokenKind.If) && !ifHasElseAhead())
			[parseVoidIf()]
			else {
				var value = parseExpression();
				[Expression(value, expressionSpan(value))];
			};
		return If(condition, thenBranch, [], start.merge(statementEnd(thenBranch)));
	}

	/**
	 * Whether the `if` at the current token has an `else`: past its condition, an `else` at the depth the `if` is at, not taken by
	 * an `if` nested in its branch, before the expression ends (a closing bracket or a comma of the enclosing one, or a semicolon
	 * not followed by `else`).
	 */
	function ifHasElseAhead():Bool {
		var cursor = position + 1, depth = 0;
		if (cursor >= tokens.length || kindAt(cursor) != TokenKind.LeftParen)
			return false;
		while (cursor < tokens.length) {
			switch kindAt(cursor) {
				case LeftParen:
					depth++;
				case RightParen:
					depth--;
				default:
			}
			cursor++;
			if (depth == 0)
				break;
		}
		var nested = 0;
		while (cursor < tokens.length) {
			switch kindAt(cursor) {
				case LeftParen, LeftBracket, LeftBrace:
					depth++;
				case RightParen, RightBracket, RightBrace:
					if (depth == 0)
						return false;
					depth--;
				case Comma:
					if (depth == 0)
						return false;
				case If:
					if (depth == 0)
						nested++;
				case Else:
					if (depth == 0) {
						if (nested == 0)
							return true;
						nested--;
					}
				case Semicolon:
					if (depth == 0)
						return nested == 0 && cursor + 1 < tokens.length && kindAt(cursor + 1) == TokenKind.Else;
				default:
			}
			cursor++;
		}
		return false;
	}

	/** A final try statement yields its branch value; throwing branches already terminate. */
	static function returnArrowValue(statements:Array<AstStatement>):Void {
		if (statements.length == 0)
			return;
		var index = statements.length - 1;
		switch statements[index] {
			case AnnotatedStatement(metadata, inner, span):
				var wrapped = [inner];
				returnArrowValue(wrapped);
				statements[index] = AnnotatedStatement(metadata, wrapped[0], span);
			case Expression(expression, span): statements[index] = Return(expression, span);
			case Try(body, catches, _):
				returnArrowValue(body);
				for (clause in catches)
					returnArrowValue(clause.statements);
			default:
		}
	}

	/** The statements of one source statement (a `var` of several names makes one per name), appended to `target` once all parsed. */
	function parseStatements(target:Array<AstStatement>):Void {
		// Parse metadata before deciding whether this is a declaration or block, while retaining private access for typing.
		if (check(TokenKind.At)) {
			var metadata = parseMetadata(), first = target.length;
			parseStatements(target);
			for (entry in metadata) {
				var scoped = scopeMetadata(entry);
				if (scoped != null)
					for (index in first...target.length)
						target[index] = AnnotatedStatement(scoped, target[index],
							entry.span.merge(statementSpan(target[index])));
			}
			return;
		}
		if (!check(TokenKind.Var) && !check(TokenKind.Final)) {
			target.push(parseStatement());
			return;
		}
		var immutable = check(TokenKind.Final);
		var start = spanOf(advance()), declarations = [];
		do {
			var nameToken = consume(TokenKind.Identifier),
				type = match(TokenKind.Colon) ? parseType() : null;
			if (match(TokenKind.Assign)) {
				var initializer = parseAnchoredExpression(textOf(nameToken) + "=");
				var span = start.merge(expressionSpan(initializer));
				declarations.push(VarDeclaration(textOf(nameToken), type, initializer, span));
				if (immutable) finalLocals.set(compiler.types.analysis.BindingWalker.key(textOf(nameToken), span),
					true);
			} else {
				if (immutable) fail(current(), "Local final declarations require an initializer");
				// Without an annotation, the typer takes the type from the first assignment, as Haxe does.
				declarations.push(UninitializedDeclaration(textOf(nameToken), type == null ? InferredType : type,
					spanTo(start, previous())));
			}
		} while (match(TokenKind.Comma));
		var lastInitializer = switch declarations[declarations.length - 1] {
			case VarDeclaration(_, _, initializer, _): initializer;
			default: null;
		};
		var end = lastInitializer != null ? expressionEnd(lastInitializer) : spanOf(consume(TokenKind.Semicolon));
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
			target.push(declaration);
	}

	function parseExpression():AstExpression {
		var expression = parseNullCoalesce();
		if (match(TokenKind.Question)) {
			var whenTrue = parseConditionalOperand();
			consume(TokenKind.Colon);
			var whenFalse = parseConditionalOperand();
			expression = Conditional(expression, whenTrue, whenFalse,
				expressionSpan(expression).merge(expressionSpan(whenFalse)));
		}
		// `expression => pattern` in a case: an extractor, matching what `expression` gives for the value (`_`) against `pattern`.
		if (patternDepth > 0 && check(TokenKind.Assign) && peekKind(1) == TokenKind.Greater) {
			advance();
			advance();
			var pattern = parseExpression();
			return Extractor(expression, pattern, expressionSpan(expression).merge(expressionSpan(pattern)));
		}
		if (check(TokenKind.Assign) && peekKind(1) != TokenKind.Greater) {
			advance();
			var value = parseExpression(),
				span = expressionSpan(expression).merge(expressionSpan(value));
			expression = switch expression {
				case Variable(name, _) if (patternDepth > 0): Capture(name, value, span);
				default: AssignmentValue(storeTo(expression, value, span,
					"Assignment expression target must be a variable, field, or array element"), span);
			};
		}
		var assignment = kindOf(current());
		if (assignment == TokenKind.PlusAssign || assignment == TokenKind.MinusAssign
			|| assignment == TokenKind.StarAssign
			|| assignment == TokenKind.SlashAssign || assignment == TokenKind.PercentAssign
			|| assignment == TokenKind.AndAssign
			|| assignment == TokenKind.OrAssign || assignment == TokenKind.XorAssign) {
			advance();
			var value = parseExpression(),
				span = expressionSpan(expression).merge(expressionSpan(value)),
				stable = AssignmentTarget.stabilize(expression, span, expressionSpan),
				target = stable.target;
			var assigned = switch assignment {
				case PlusAssign: Add(target, value, span);
				case MinusAssign: Sub(target, value, span);
				case StarAssign: Mul(target, value, span);
				case SlashAssign: Div(target, value, span);
				case PercentAssign: Mod(target, value, span);
				case AndAssign: BitAnd(target, value, span);
				case OrAssign: BitOr(target, value, span);
				case XorAssign: BitXor(target, value, span);
				default: value;
			};
			expression = assignmentValue(stable.bindings, storeTo(target, assigned, span,
				"Assignment expression target must be a variable, field, or array element"), span);
		}
		return expression;
	}

	/** The store of `value` to `target`, a variable, field or array element, as an assignment statement. */
	function storeTo(target:AstExpression, value:AstExpression, span:SourceSpan, message:String):AstStatement
		return switch target {
			case Variable(name, _): Assignment(name, value, span);
			case Index(array, offset, _): IndexAssignment(array, offset, value, span);
			case Member(object, field, _): FieldAssignment(object, field, value, span);
			default: throw new CompileError(new Diagnostic("E0002", message, expressionSpan(target)));
		};

	/** `store` as a value, after the bindings that make its target stable (`AssignmentTarget`). */
	static function assignmentValue(bindings:Array<AstStatement>, store:AstStatement, span:SourceSpan):AstExpression
		return bindings.length == 0 ? AssignmentValue(store, span) : BlockExpression(bindings,
			AssignmentValue(store, span), span);

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
				Conditional(Equal(local, NullLiteral(expressionSpan(local)), expressionSpan(local)), fallback, local,
				span), span);
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
		// The `<` of `<<=` (and the `>` of `>>=`, `>>>=`) starts a compound assignment, not a comparison.
		if ((check(TokenKind.Less) || check(TokenKind.LessEqual) || check(TokenKind.Greater)
			|| check(TokenKind.EqualEqual) || check(TokenKind.NotEqual))
			&& shiftAssignmentKind() < 0) {
			var operation = kindOf(advance());
			if (operation == TokenKind.Greater && check(TokenKind.Assign)
				&& endOf(previous()) == startOf(current())) {
				advance();
				operation = TokenKind.GreaterEqual;
			}
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
		while ((isAdjacentPair(TokenKind.Less) || isAdjacentPair(TokenKind.Greater)) && shiftAssignmentKind() < 0) {
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

	/** 9 for `<<=`, 10 for `>>=`, 11 for `>>>=`, or -1; nothing is consumed. */
	function shiftAssignmentKind():Int {
		if (check(TokenKind.Less) && peekKind(1) == TokenKind.LessEqual
			&& endOf(current()) == startOf(ahead(1)))
			return 9;
		if (isAdjacentPair(TokenKind.Greater)
			&& peekKind(2) == TokenKind.Assign
			&& endOf(ahead(1)) == startOf(ahead(2)))
			return 10;
		if (isAdjacentTriple(TokenKind.Greater)
			&& peekKind(3) == TokenKind.Assign
			&& endOf(ahead(2)) == startOf(ahead(3)))
			return 11;
		return -1;
	}

	function isAdjacentPair(kind:TokenKind):Bool
		return check(kind) && peekKind(1) == kind && endOf(current()) == startOf(ahead(1));

	function isAdjacentTriple(kind:TokenKind):Bool
		return isAdjacentPair(kind) && peekKind(2) == kind
			&& endOf(ahead(1)) == startOf(ahead(2));

	function parseAdditive():AstExpression {
		var expression = parseMultiplicative();
		while (check(TokenKind.Plus) || check(TokenKind.Minus)) {
			var operation = kindOf(advance());
			var right = parseMultiplicative();
			var span = expressionSpan(expression).merge(expressionSpan(right));
			expression = operation == TokenKind.Plus ? Add(expression, right, span) : Sub(expression, right, span);
		}
		return expression;
	}

	function parseMultiplicative():AstExpression {
		var expression = parseModulo();
		while (check(TokenKind.Star) || check(TokenKind.Slash)) {
			var operation = kindOf(advance()),
				right = parseModulo(),
				span = expressionSpan(expression).merge(expressionSpan(right));
			expression = operation == TokenKind.Star ? Mul(expression, right, span) : Div(expression, right, span);
		}
		return expression;
	}

	/** `%` binds tighter than `*` and `/` in Haxe: `a * b % c` is `a * (b % c)`. */
	function parseModulo():AstExpression {
		var expression = parsePrimary();
		while (match(TokenKind.Percent)) {
			var right = parsePrimary(),
				span = expressionSpan(expression).merge(expressionSpan(right));
			expression = Mod(expression, right, span);
		}
		return expression;
	}

	/** Whether the parentheses at the current token are a typed cast's `(value, Type)`: a comma directly inside them. */
	function parenthesesHoldTypedCast():Bool {
		var depth = 0, offset = 0;
		while (true) {
			switch peekKind(offset++) {
				case LeftParen | LeftBracket | LeftBrace:
					depth++;
				case RightParen | RightBracket | RightBrace:
					if (--depth == 0)
						return false;
				case Comma if (depth == 1):
					return true;
				case Eof:
					return false;
				default:
			}
		}
	}

	function parsePrimary():AstExpression {
		if (match(TokenKind.Backslash))
			return parseKeyPathLiteral(spanOf(previous()));
		if (recovering && isExpressionTerminator(kindOf(current()))) {
			var span = new SourceSpan(spanOf(current()).file, startOf(current()), startOf(current()));
			recordRecoveryDiagnostic(new compiler.core.Diagnostic("E0002", "Expected expression", span));
			return ErrorExpression(span);
		}
		if (check(TokenKind.At)) {
			var metadata = parseMetadata(), expression = parsePrimary();
			for (entry in metadata) {
				var scoped = scopeMetadata(entry);
				if (scoped != null)
					expression = AnnotatedExpression(scoped, expression, entry.span.merge(expressionSpan(expression)));
			}
			return expression;
		}
		if (match(TokenKind.Switch))
			return parseSwitchExpression(spanOf(previous()));
		if (match(TokenKind.Try))
			return parseTryExpression(spanOf(previous()));
		if (match(TokenKind.Throw)) {
			var start = spanOf(previous()), value = parseExpression();
			return ThrowExpression(value, start.merge(expressionSpan(value)));
		}
		if (check(TokenKind.Identifier) && textOf(current()) == "cast") {
			var start = spanOf(advance());
			if (check(TokenKind.LeftParen) && parenthesesHoldTypedCast()) {
				advance();
				var value = parseExpression();
				consume(TokenKind.Comma);
				var target = parseType(), end = spanOf(consume(TokenKind.RightParen));
				return parsePostfix(Cast(value, target, start.merge(end)));
			}
			// An unsafe cast takes the whole expression to its right, as in Haxe: `cast (x) % 2` casts `(x) % 2`.
			var value = parseExpression();
			return Cast(value, null, start.merge(expressionSpan(value)));
		}
		if (match(TokenKind.Function)) {
			var start = spanOf(previous()), identity = openLambda();
			consume(TokenKind.LeftParen);
			var arguments:Array<AstArgument> = [];
			if (!check(TokenKind.RightParen))
				do {
					var rest = matchEllipsis(),
						optional = match(TokenKind.Question),
						argument = consume(TokenKind.Identifier),
						type = restType(rest, match(TokenKind.Colon) ? parseType() : InferredType),
						defaultValue = match(TokenKind.Assign) ? parseExpression() : null;
					arguments.push({
						name: textOf(argument),
						type: type,
						span: spanBetween(argument, previous()),
						optional: optional,
						defaultValue: defaultValue
					});
				} while (match(TokenKind.Comma));
			rejectEarlyRest(arguments);
			consume(TokenKind.RightParen);
			var result = match(TokenKind.Colon) ? parseType() : null,
				body = parseAnonymousFunctionBody(),
				end = body.length == 0 ? spanOf(previous()) : statementSpan(body[body.length - 1]),
				span = start.merge(end);
			closeLambda();
			if (result == null)
				return Lambda(arguments, body, identity, span);
			// Lambda carries no result type; bind it through a typed local like a named local function.
			var name = "$typedLambda@" + identity;
			return BlockExpression([
				VarDeclaration(name, localFunctionType(arguments, result), Lambda(arguments, body, identity, span),
					span)
			], Variable(name, span), span);
		}
		if (check(TokenKind.Identifier) && peekKind(1) == TokenKind.Arrow) {
			var argument = advance(),
				start = spanOf(argument),
				identity = openLambda();
			advance();
			var arguments:Array<AstArgument> = [
				{
					name: textOf(argument),
					type: InferredType,
					span: spanOf(argument),
					optional: false,
					defaultValue: null
				}
			],
				body = parseArrowFunctionBody();
			closeLambda();
			return Lambda(arguments, body, identity,
				start.merge(body.length == 0 ? spanOf(previous()) : statementSpan(body[body.length - 1])));
		}
		if (match(TokenKind.If)) {
			var start = spanOf(previous());
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
			var start = spanOf(previous());
			if (match(TokenKind.Integer)) {
				var token = previous(), value = parseIntegerToken(token, true);
				return parsePostfix(IntegerLiteral(value, spanTo(start, token)));
			}
			var value = parsePrimary();
			return Negate(value, start.merge(expressionSpan(value)));
		}
		if (match(TokenKind.Not)) {
			var start = spanOf(previous()), value = parsePrimary();
			return Not(value, start.merge(expressionSpan(value)));
		}
		if (match(TokenKind.BitNot)) {
			var start = spanOf(previous()), value = parsePrimary();
			return BitXor(value, IntegerLiteral(-1, start), start.merge(expressionSpan(value)));
		}
		if (match(TokenKind.Increment) || match(TokenKind.Decrement)) {
			// Prefix `++x`/`--x` update the target and evaluate to its new value (a setter's result, as Haxe's),
			// lowered like an assignment expression. Field and index targets are
			// stabilized first so their receiver and index are evaluated once.
			var start = spanOf(previous()),
				delta = kindOf(previous()) == TokenKind.Increment ? 1 : -1,
				target = parsePrimary(),
				span = start.merge(expressionSpan(target)),
				stabilized = AssignmentTarget.stabilize(target, span, expressionSpan),
				bindings = stabilized.bindings;
			target = stabilized.target;
			return assignmentValue(bindings, storeTo(target, Add(target, IntegerLiteral(delta, start), span), span,
				"Prefix increment target must be a variable, field, or array element"), span);
		}
		if (match(TokenKind.Integer)) {
			var token = previous();
			return parsePostfix(IntegerLiteral(parseIntegerToken(token), spanOf(token)));
		}
		if (match(TokenKind.Float))
			return parsePostfix(FloatLiteral(Std.parseFloat(normalizeNumericLiteral(textOf(previous()))),
				spanOf(previous())));
		if (match(TokenKind.StringLiteral))
			return parsePostfix(parseStringExpression(previous()));
		if (match(TokenKind.RegexLiteral)) {
			var token = previous(),
				delimiter = textOf(token).lastIndexOf("/"),
				pattern = StringTools.replace(textOf(token).substring(2, delimiter), "\\/", "/"),
				options = textOf(token).substring(delimiter + 1);
			return parsePostfix(New("EReg", [
				StringLiteral(pattern, spanOf(token)),
				StringLiteral(options, spanOf(token))
			],
				spanOf(token)));
		}
		if (match(TokenKind.BoolTrue))
			return parsePostfix(BoolLiteral(true, spanOf(previous())));
		if (match(TokenKind.BoolFalse))
			return parsePostfix(BoolLiteral(false, spanOf(previous())));
		if (match(TokenKind.LeftBracket)) {
			var start = spanOf(previous()), values = [];
			if (match(TokenKind.For)) {
				consume(TokenKind.LeftParen);
				var keyName = textOf(consume(TokenKind.Identifier)),
					valueName = null;
				if (match(TokenKind.Assign)) {
					consume(TokenKind.Greater);
					valueName = textOf(consume(TokenKind.Identifier));
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
				if (condition != null && check(TokenKind.Else)) {
					value = parseComprehensionElse(condition, value);
					condition = null;
				}
				if (match(TokenKind.Assign)) {
					consume(TokenKind.Greater);
					var mapValue = parseComprehensionValue(),
						end = spanOf(consume(TokenKind.RightBracket));
					return parsePostfix(MapComprehension(keyName, valueName, iterable, condition, value, mapValue,
						start.merge(end)));
				}
				var end = spanOf(consume(TokenKind.RightBracket));
				return parsePostfix(ArrayComprehension(keyName, valueName, iterable, condition, value, false,
					start.merge(end)));
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
						entries.push({
							key: key,
							value: entryValue,
							span: expressionSpan(key).merge(expressionSpan(entryValue))
						});
					}
					var end = spanOf(consume(TokenKind.RightBracket));
					return parsePostfix(MapLiteral(entries, start.merge(end)));
				}
				values.push(first);
				while (match(TokenKind.Comma))
					if (!check(TokenKind.RightBracket))
						values.push(parseExpression());
			}
			var end = spanOf(consume(TokenKind.RightBracket));
			return parsePostfix(ArrayLiteral(values, start.merge(end)));
		}
		if (check(TokenKind.Identifier) && textOf(current()) == "null") {
			var nullToken = advance();
			return parsePostfix(NullLiteral(spanOf(nullToken)));
		}
		if (match(TokenKind.New)) {
			var start = spanOf(previous());
			if (check(TokenKind.Identifier) && textOf(current()) == "List") {
				advance();
				var typeArguments = check(TokenKind.Less) ? parseTypeArguments() : [];
				consume(TokenKind.LeftParen);
				var end = spanOf(consume(TokenKind.RightParen));
				if (typeArguments.length > 0) {
					if (typeArguments.length != 1)
						fail(previous(), 'List expects 1 type argument, got ${typeArguments.length}');
					return parsePostfix(NewArray(typeArguments[0], IntegerLiteral(0, end), start.merge(end)));
				}
				return parsePostfix(ArrayLiteral([], start.merge(end)));
			}
			if (check(TokenKind.Identifier) && textOf(current()) == "Array") {
				advance();
				if (match(TokenKind.LeftParen)) {
					var end = spanOf(consume(TokenKind.RightParen));
					return parsePostfix(ArrayLiteral([], start.merge(end)));
				}
				consume(TokenKind.Less);
				var element = parseType();
				consume(TokenKind.Greater);
				consume(TokenKind.LeftParen);
				if (check(TokenKind.RightParen)) {
					var end = spanOf(advance());
					return parsePostfix(NewArray(element, IntegerLiteral(0, end), start.merge(end)));
				}
				var length = parseExpression();
				var end = spanOf(consume(TokenKind.RightParen));
				return parsePostfix(NewArray(element, length, start.merge(end)));
			}
			if (check(TokenKind.Identifier) && textOf(current()) == "Map") {
				advance();
				if (match(TokenKind.LeftParen)) {
					var end = spanOf(consume(TokenKind.RightParen));
					return parsePostfix(MapLiteral([], start.merge(end)));
				}
				consume(TokenKind.Less);
				var key = parseType();
				consume(TokenKind.Comma);
				var value = parseType();
				consume(TokenKind.Greater);
				consume(TokenKind.LeftParen);
				var end = spanOf(consume(TokenKind.RightParen));
				return parsePostfix(NewMap(key, value, start.merge(end)));
			}
			var typeName = parseQualifiedName();
			var typeArguments = parseTypeArguments();
			consume(TokenKind.LeftParen);
			var arguments = parseCallArguments(typeName);
			var end = spanOf(consume(TokenKind.RightParen));
			return parsePostfix(typeArguments.length == 0 ? New(typeName, arguments,
				start.merge(end)) : NewGeneric(typeName, typeArguments, arguments, start.merge(end)));
		}
		if (check(TokenKind.LeftParen)) {
			var saved = position,
				start = spanOf(current()),
				isLambda = parenthesizedLambdaAhead();
			if (!isLambda) {
				advance();
				var grouped = parseExpression();
				if (match(TokenKind.Colon)) {
					var target = parseType(),
						end = spanOf(consume(TokenKind.RightParen));
					grouped = CheckType(grouped, target, start.merge(end));
				} else
					consume(TokenKind.RightParen);
				return parsePostfix(grouped);
			}
			advance();
			var arguments:Array<AstArgument> = [];
			if (!check(TokenKind.RightParen)) {
				do {
					var optional = match(TokenKind.Question),
						argumentStart = spanOf(current()),
						argumentName = textOf(consume(TokenKind.Identifier));
					var argumentType = match(TokenKind.Colon) ? parseType() : InferredType,
						defaultValue = match(TokenKind.Assign) ? parseExpression() : null;
					arguments.push({
						name: argumentName,
						type: argumentType,
						span: spanTo(argumentStart, previous()),
						optional: optional,
						defaultValue: defaultValue
					});
				} while (match(TokenKind.Comma));
			}
			consume(TokenKind.RightParen);
			if (match(TokenKind.Arrow)) {
				var identity = openLambda(), body = parseArrowFunctionBody();
				closeLambda();
				return Lambda(arguments, body, identity,
					start.merge(body.length == 0 ? spanOf(previous()) : statementSpan(body[body.length - 1])));
			}
			position = saved;
			advance();
			var grouped = parseExpression();
			consume(TokenKind.Colon);
			var target = parseType(), end = spanOf(consume(TokenKind.RightParen));
			return parsePostfix(CheckType(grouped, target, start.merge(end)));
		}
		if (match(TokenKind.This)) {
			var start = spanOf(previous()), end = start, name = "this";
			while (check(TokenKind.Dot) && peekKind(1) != TokenKind.Dot) {
				advance();
				var part = consumeName();
				name += "." + textOf(part);
				end = spanOf(part);
			}
			var referenceSpan = new SourceSpan(start.file, start.start, end.end);
			var expression:AstExpression = Variable(name, referenceSpan);
			return parsePostfix(expression);
		}
		// `{` opens an object literal when empty or starting with `name:` or `"name":`, and a block expression valued by its last expression
		// otherwise.
		if (check(TokenKind.LeftBrace)
			&& peekKind(1) != TokenKind.RightBrace
			&& !((peekKind(1) == TokenKind.Identifier || peekKind(1) == TokenKind.StringLiteral)
			&& peekKind(2) == TokenKind.Colon))
			return parseExpressionBranch();
		if (match(TokenKind.LeftBrace)) {
			var start = spanOf(previous()), fields = [];
			if (!check(TokenKind.RightBrace)) {
				while (true) {
					// As in Haxe, a field may be named by a string, as JSON-shaped data names fields that are keywords: `{"package": p}`.
					var name = check(TokenKind.StringLiteral) ? advance() : consume(TokenKind.Identifier),
						fieldName = kindOf(name) == TokenKind.StringLiteral ? decodeString(textOf(name),
							spanOf(name)) : textOf(name);
					consume(TokenKind.Colon);
					var value = parseAnchoredExpression("{" + fieldName + "}");
					fields.push({name: fieldName, value: value, span: spanOf(name).merge(expressionSpan(value))});
					if (!match(TokenKind.Comma) || check(TokenKind.RightBrace))
						break;
				}
			}
			var end = spanOf(consume(TokenKind.RightBrace));
			return parsePostfix(ObjectLiteral(fields, start.merge(end)));
		}
		if (check(TokenKind.Identifier)
			&& peekKind(1) == TokenKind.Less
			&& (textOf(current()) == "sizeof"
			|| textOf(current()) == "alignof"
			|| textOf(current()) == "offsetof"
			|| textOf(current()) == "typeInfo"))
			return parseNativeLayoutQuery();
		// `abstract` in an abstract's method is a value, as `this` is, so `abstract.label()` is a call on it.
		if (check(TokenKind.Identifier) && textOf(current()) == "abstract")
			return parsePostfix(Variable("abstract", SourceSpan.reference(spanOf(current()).file, startOf(advance()),
				endOf(previous()), true)));
		if (isNameToken(kindOf(current()))) {
			var nameToken = consumeName(), name = textOf(nameToken), end = nameToken;
			while (check(TokenKind.Dot) && peekKind(1) != TokenKind.Dot) {
				advance();
				var part = consumeName();
				name += "." + textOf(part);
				end = part;
			}
			var referenceSpan = SourceSpan.reference(fileOf(nameToken), startOf(nameToken), endOf(end),
				name.indexOf(".") < 0);
			var expression:AstExpression = Variable(name, referenceSpan);
			if (match(TokenKind.LeftParen)) {
				var arguments = StringTools.endsWith(name, ".match")
					? parseMatchPattern(name) : parseCallArguments(name);
				var close = consume(TokenKind.RightParen);
				expression = Call(name, arguments,
					SourceSpan.reference(referenceSpan.file, referenceSpan.start, endOf(close),
					referenceSpan.isBareReference));
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
		var name = consume(TokenKind.Identifier), kind = switch textOf(name) {
			case "sizeof": SizeOf;
			case "alignof": AlignOf;
			case "offsetof": OffsetOf;
			case "typeInfo": TypeInfo;
			default: throw new InternalError("Invalid native layout query");
		};
		consume(TokenKind.Less);
		var type = parseType();
		consume(TokenKind.Greater);
		consume(TokenKind.LeftParen);
		var field:Null<String> = null;
		if (kind == OffsetOf) {
			var token = consume(TokenKind.StringLiteral);
			field = decodeString(textOf(token), spanOf(token));
		}
		var end = spanOf(consume(TokenKind.RightParen));
		return parsePostfix(NativeLayoutQuery(kind, type, field, spanOf(name).merge(end)));
	}

	static function isExpressionTerminator(kind:TokenKind):Bool
		return switch kind {
			case TokenKind.Semicolon, TokenKind.Comma, TokenKind.RightParen, TokenKind.RightBracket,
				TokenKind.RightBrace, TokenKind.Eof: true;
			default: false;
		};

	function parenthesizedLambdaAhead():Bool {
		var depth = 0, cursor = position;
		while (cursor < tokens.length) {
			switch kindAt(cursor) {
				case LeftParen:
					depth++;
				case RightParen:
					depth--;
					if (depth == 0)
						return cursor + 1 < tokens.length && kindAt(cursor + 1) == TokenKind.Arrow;
				default:
			}
			cursor++;
		}
		return false;
	}

	function parseComprehensionValue():AstExpression {
		if (match(TokenKind.For))
			return parseNestedArrayComprehension(spanOf(previous()));
		if (check(TokenKind.LeftBrace) && !(peekKind(1) == TokenKind.Identifier && peekKind(2) == TokenKind.Colon))
			return parseExpressionBranch(true);
		return parseExpression();
	}

	/**
	 * A comprehension body block that ends in an `if` without `else` yields a
	 * value only when the condition holds, as in Haxe. It lowers to a nested,
	 * flattened comprehension over a zero- or one-element array:
	 * `{ S; if (c) v; }` becomes `for (y in { S; c ? [v] : []; }) y`.
	 */
	static function filteredComprehensionValue(statements:Array<AstStatement>, span:SourceSpan):Null<AstExpression> {
		var yielded = yieldedValues(statements, span);
		if (yielded == null)
			return null;
		var name = "__haxeon_yield";
		return ArrayComprehension(name, null, yielded, null, Variable(name, span), true, span);
	}

	/** The block's values as an array of zero or one elements, or null when a path yields nothing expressible. */
	static function yieldedValues(statements:Array<AstStatement>, span:SourceSpan):Null<AstExpression> {
		if (statements.length == 0)
			return null;
		var last = statements[statements.length - 1],
			prefix = statements.slice(0, statements.length - 1);
		var result:Null<AstExpression> = switch last {
			case AstStatement.Expression(value, valueSpan): ArrayLiteral([value], valueSpan);
			case AstStatement.If(predicate, whenTrue, whenFalse, ifSpan): var yes = yieldedValues(whenTrue,
				ifSpan);
				var no = whenFalse.length == 0 ? ArrayLiteral([],
					ifSpan) : yieldedValues(whenFalse, ifSpan);
				yes == null || no == null ? null : Conditional(predicate, yes, no, ifSpan);
			case _: null;
		};
		if (result == null)
			return null;
		return prefix.length == 0 ? result : BlockExpression(prefix, result, span);
	}

	/**
	 * `for (x in xs) if (c) a else b`: the `if` after the header is not a filter but the start of the value once an
	 * `else` follows it. Every arm yields a value when the chain ends in a plain `else`, so it is nested
	 * conditionals; when the last `if` has no `else`, no value is yielded if no condition holds, which lowers like a
	 * comprehension body that ends in an `if` without `else` (see `filteredComprehensionValue`).
	 */
	function parseComprehensionElse(condition:AstExpression, value:AstExpression):AstExpression {
		var arms = [{condition: condition, value: value}],
			tail:Null<AstExpression> = null;
		while (match(TokenKind.Else)) {
			if (match(TokenKind.If)) {
				consume(TokenKind.LeftParen);
				var armCondition = parseExpression();
				consume(TokenKind.RightParen);
				arms.push({condition: armCondition, value: parseComprehensionValue()});
				continue;
			}
			tail = parseComprehensionValue();
			break;
		}
		var span = expressionSpan(condition).merge(expressionSpan(tail == null ? arms[arms.length - 1].value : tail));
		var index = arms.length;
		if (tail != null) {
			var chained = tail;
			while (index > 0) {
				index--;
				chained = Conditional(arms[index].condition, arms[index].value, chained, span);
			}
			return chained;
		}
		var yielded:AstExpression = ArrayLiteral([], span);
		while (index > 0) {
			index--;
			yielded = Conditional(arms[index].condition, ArrayLiteral([arms[index].value], span), yielded, span);
		}
		var name = "__haxeon_yield";
		return ArrayComprehension(name, null, yielded, null, Variable(name, span), true, span);
	}

	function parseNestedArrayComprehension(start:SourceSpan):AstExpression {
		consume(TokenKind.LeftParen);
		var keyName = textOf(consume(TokenKind.Identifier)), valueName = null;
		if (match(TokenKind.Assign)) {
			consume(TokenKind.Greater);
			valueName = textOf(consume(TokenKind.Identifier));
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
		if (condition != null && check(TokenKind.Else)) {
			value = parseComprehensionElse(condition, value);
			condition = null;
		}
		return ArrayComprehension(keyName, valueName, iterable, condition, value, true,
			start.merge(expressionSpan(value)));
	}

	/** An operand of `c ? a : b`: a value, so `{}` is an empty object there, as in Haxe, not an empty block. */
	function parseConditionalOperand():AstExpression
		return check(TokenKind.LeftBrace)
			&& peekKind(1) == TokenKind.RightBrace ? parseExpression() : parseExpressionBranch();

	function parseExpressionBranch(comprehensionValue:Bool = false):AstExpression {
		if (!check(TokenKind.LeftBrace)
			|| ((peekKind(1) == TokenKind.Identifier || peekKind(1) == TokenKind.StringLiteral)
			&& peekKind(2) == TokenKind.Colon))
			return parseExpression();
		advance();
		var start = spanOf(previous()), statements = [];
		while (!check(TokenKind.RightBrace) && !check(TokenKind.Eof)) {
			if (isStatementOnlyStart(kindOf(current()))) {
				parseStatements(statements);
				continue;
			}
			if (check(TokenKind.LeftBrace)
				&& !(peekKind(1) == TokenKind.Identifier && peekKind(2) == TokenKind.Colon)) {
				var result = parseExpressionBranch();
				match(TokenKind.Semicolon);
				if (check(TokenKind.RightBrace)) {
					var end = spanOf(consume(TokenKind.RightBrace));
					return BlockExpression(statements, result, start.merge(end));
				}
				statements.push(Expression(result, expressionSpan(result)));
				continue;
			}
			var saved = position,
				savedLambdas = lambdaMark(),
				candidate = tryParseExpression();
			if (candidate != null && check(TokenKind.RightBrace)) {
				var end = spanOf(consume(TokenKind.RightBrace));
				return BlockExpression(statements, candidate, start.merge(end));
			}
			position = saved;
			rewindLambdas(savedLambdas);
			parseStatements(statements);
		}
		var trailing = trailingBlockResult(statements);
		if (trailing != null) {
			var end = spanOf(consume(TokenKind.RightBrace));
			return BlockExpression(trailing.statements, trailing.result, start.merge(end));
		}
		if (comprehensionValue && check(TokenKind.RightBrace)) {
			var filtered = filteredComprehensionValue(statements, spanTo(start, current()));
			if (filtered != null) {
				consume(TokenKind.RightBrace);
				return filtered;
			}
		}
		// A block that always leaves, like `{ log(); throw error; }`, never yields a value.
		if (statements.length > 0 && statementTerminates(statements[statements.length - 1])
			&& check(TokenKind.RightBrace)) {
			var last = statementSpan(statements[statements.length - 1]),
				end = spanOf(consume(TokenKind.RightBrace));
			return BlockExpression(statements, Unreachable(last), start.merge(end));
		}
		if (recoveringAtEnd()) {
			var span = spanOf(current());
			recordRecoveryDiagnostic(new compiler.core.Diagnostic("E0002",
				"Expression block requires a result expression",
				span));
			return ErrorExpression(span);
		}
		fail(current(), "Expression block requires a result expression");
		return null;
	}

	static function trailingBlockResult(statements:Array<AstStatement>):Null<{
		statements:Array<AstStatement>,
		result:AstExpression
	}> {
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
					statements:prefix,
						result:Conditional(predicate, blockResultExpression(trueResult),
						blockResultExpression(falseResult), span)
				};
			case _: null;
		};
	}

	static function blockResultExpression(block:{statements:Array<AstStatement>, result:AstExpression}):AstExpression
		return block.statements.length == 0 ? block.result : BlockExpression(block.statements, block.result,
			statementSpan(block.statements[0]).merge(expressionSpan(block.result)));

	function parseSwitchExpression(start:SourceSpan):AstExpression {
		// A parenthesized subject is an ordinary grouped expression; see the statement form.
		var subject = parseExpression();
		consume(TokenKind.LeftBrace);
		var cases = [];
		while (match(TokenKind.Case)) {
			var caseStart = spanOf(previous()),
				values = parseCasePatterns();
			var guard = parseSwitchGuard();
			consume(TokenKind.Colon);
			var result = parseSwitchExpressionBranch();
			cases.push({
				patterns: values,
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
		var end = spanOf(consume(TokenKind.RightBrace));
		return parsePostfix(SwitchExpression(subject, cases, fallback, start.merge(end)));
	}

	/** The comma-separated patterns of one `case`, with `|` alternatives expanded into separate patterns. */
	function parseCasePatterns():Array<AstExpression> {
		patternDepth++;
		try {
			var values = expandPatternAlternatives(parseExpression());
			while (match(TokenKind.Comma))
				appendExpressions(values, expandPatternAlternatives(parseExpression()));
			patternDepth--;
			return values;
		} catch (error:CompileError) {
			patternDepth--;
			throw error;
		}
	}

	/** The argument of `value.match(pattern)`, parsed as a case pattern so it may capture. */
	function parseMatchPattern(callee:String):Array<AstExpression> {
		patternDepth++;
		try {
			var arguments = parseCallArguments(callee);
			patternDepth--;
			return arguments;
		} catch (error:CompileError) {
			patternDepth--;
			throw error;
		}
	}

	static function appendExpressions(target:Array<AstExpression>, values:Array<AstExpression>):Void
		for (value in values)
			target.push(value);

	/** The patterns `pattern` stands for, one per combination of its alternatives (`A | B`, `Pair(A | B, _)`). */
	public static function expandPatternAlternatives(pattern:AstExpression):Array<AstExpression>
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
			case Capture(name, inner, span):
				[for (alternative in expandPatternAlternatives(inner)) Capture(name, alternative, span)];
			case Extractor(expression, inner, span):
				[for (alternative in expandPatternAlternatives(inner)) Extractor(expression, alternative, span)];
			case _: [pattern];
		};

	static function expandCallPattern(name:String, arguments:Array<AstExpression>,
			span:SourceSpan):Array<AstExpression> {
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

	/**
	 * `try value catch (e:T) caught` is the block `{ var result; try result = value catch (e:T) result = caught; result }`,
	 * so a `return`, `break` or `continue` in a catch leaves the enclosing function or loop, as in Haxe, and nothing is
	 * allocated for it. The block's expected type is its result local's (`typeBlockExpression`).
	 */
	function parseTryExpression(start:SourceSpan):AstExpression {
		var value = parseExpressionBranch(),
			catches:Array<compiler.syntax.Ast.AstCatch> = [],
			end = expressionSpan(value),
			result = '$' + 'try:${start.start}';
		do {
			var catchStart = spanOf(consume(TokenKind.Catch));
			consume(TokenKind.LeftParen);
			var name = textOf(consume(TokenKind.Identifier));
			// As in Haxe, `catch (e)` with no type catches everything.
			var type = match(TokenKind.Colon) ? parseType() : NamedType("Dynamic");
			consume(TokenKind.RightParen);
			var caught = parseExpressionBranch();
			end = expressionSpan(caught);
			catches.push({
				name: name,
				type: type,
				statements: [Assignment(result, caught, catchStart.merge(end))],
				span: catchStart.merge(end)
			});
		} while (check(TokenKind.Catch));
		var span = start.merge(end);
		return parsePostfix(BlockExpression([
			UninitializedDeclaration(result, InferredType, start),
			Try([Assignment(result, value, expressionSpan(value))], catches, span)
		], Variable(result, span), span));
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
		var statements = [], start = spanOf(current());
		while (true) {
			if (atSwitchBranchEnd() && statements.length == 0)
				return EmptyExpression(spanTo(start, current()));
			if (atSwitchBranchEnd() && statements.length > 0) {
				// Statements that end the branch: it never completes if the last one leaves, else its value is Void.
				var last = statements[statements.length - 1],
					end = statementSpan(last);
				return BlockExpression(statements, statementTerminates(last) ? Unreachable(end) : EmptyExpression(end),
					start.merge(end));
			}
			if (isStatementOnlyStart(kindOf(current()))) {
				parseStatements(statements);
				continue;
			}
			if (check(TokenKind.LeftBrace)
				&& !(peekKind(1) == TokenKind.Identifier && peekKind(2) == TokenKind.Colon)) {
				var result = parseExpressionBranch();
				match(TokenKind.Semicolon);
				if (atSwitchBranchEnd())
					return statements.length == 0 ? result : BlockExpression(statements, result,
						start.merge(expressionSpan(result)));
				statements.push(Expression(result, expressionSpan(result)));
				continue;
			}
			var saved = position,
				savedLambdas = lambdaMark(),
				result = tryParseExpression();
			if (result != null && match(TokenKind.Semicolon)) {
				if (atSwitchBranchEnd())
					return statements.length == 0 ? result : BlockExpression(statements, result,
						start.merge(expressionSpan(result)));
				position = saved;
				rewindLambdas(savedLambdas);
				parseStatements(statements);
				continue;
			}
			if (result != null && atSwitchBranchEnd())
				return statements.length == 0 ? result : BlockExpression(statements, result,
					start.merge(expressionSpan(result)));
			position = saved;
			rewindLambdas(savedLambdas);
			parseStatements(statements);
		}
	}

	function atSwitchBranchEnd():Bool
		return check(TokenKind.Case) || check(TokenKind.Default) || check(TokenKind.RightBrace) || recoveringAtEnd();

	static function statementTerminates(statement:AstStatement):Bool
		return switch statement {
			case Return(_, _), ReturnVoid(_), Throw(_, _), Break(_), Continue(_): true;
			case If(_, yes, no, _): yes.length > 0 && no.length > 0 && statementTerminates(yes[yes.length - 1])
				&& statementTerminates(no[no.length - 1]);
			default: false;
		};

	static function isStatementOnlyStart(kind:TokenKind):Bool
		return switch kind {
			case TokenKind.Var, TokenKind.Return, TokenKind.Try, TokenKind.While, TokenKind.Do, TokenKind.For,
				TokenKind.Break, TokenKind.Continue: true;
			default: false;
		};

	function tryParseExpression():Null<AstExpression> {
		var saved = position, savedLambdas = lambdaMark();
		try {
			return parseExpression();
		} catch (_:CompileError) {
			position = saved;
			rewindLambdas(savedLambdas);
			return null;
		}
	}

	function parsePostfix(expression:AstExpression):AstExpression {
		while (true) {
			if (check(TokenKind.Dot) && peekKind(1) == TokenKind.Dot && peekKind(2) == TokenKind.Dot)
				break;
			if (match(TokenKind.LeftParen)) {
				var arguments = parseCallArguments(switch expression {
					case Variable(name, _): name;
					default: "";
				});
				var end = spanOf(consume(TokenKind.RightParen));
				expression = switch expression {
					case Variable(name, start): Call(name, arguments,
						SourceSpan.reference(start.file, start.start, end.end, start.isBareReference));
					default: ClosureCall(expression, arguments, expressionSpan(expression).merge(end));
				};
				continue;
			}
			if (match(TokenKind.LeftBracket)) {
				var offset = parseExpression(),
					end = spanOf(consume(TokenKind.RightBracket));
				expression = Index(expression, offset, expressionSpan(expression).merge(end));
				continue;
			}
			if (match(TokenKind.Dot)) {
				if (recovering && isExpressionTerminator(kindOf(current()))) {
					var span = new SourceSpan(spanOf(current()).file, startOf(current()), startOf(current()));
					recordRecoveryDiagnostic(new compiler.core.Diagnostic("E0002", "Expected member name", span));
					break;
				}
				var nameToken = consumeName(), name = textOf(nameToken);
				if (match(TokenKind.LeftParen)) {
					var arguments = name == "match" ? parseMatchPattern(name) : parseCallArguments(name);
					var end = spanOf(consume(TokenKind.RightParen));
					expression = MethodCall(expression, name, arguments, expressionSpan(expression).merge(end));
				} else
					expression = Member(expression, name, spanTo(expressionSpan(expression), nameToken));
				continue;
			}
			if (match(TokenKind.Increment) || match(TokenKind.Decrement)) {
				var end = spanOf(previous()),
					delta = kindOf(previous()) == TokenKind.Increment ? 1 : -1;
				expression = PostfixIncrement(expression, delta, expressionSpan(expression).merge(end));
				break;
			}
			break;
		}
		return expression;
	}

	function parseType():AstType {
		if (match(TokenKind.LeftParen)) {
			var arguments = [], optionals:Array<Bool> = [];
			if (!check(TokenKind.RightParen)) {
				do {
					// `(...Int)->Int`, `(...values:Int)->Int`: a rest parameter is a `haxe.Rest<T>`, as in Haxe, which does not
					// require it last in a type.
					var rest = matchEllipsis();
					var optional = match(TokenKind.Question);
					if (check(TokenKind.Identifier) && peekKind(1) == TokenKind.Colon) {
						advance();
						advance();
					}
					var argument = restType(rest, parseType());
					arguments.push(optional ? NullableType(argument) : argument);
					optionals.push(optional);
				} while (match(TokenKind.Comma));
			}
			consume(TokenKind.RightParen);
			consume(TokenKind.Arrow);
			return chainedFunctionType(arguments, parseType(), optionals);
		}
		var atomic = parseAtomicType();
		if (match(TokenKind.Arrow))
			return chainedFunctionType(switch atomic {
				case VoidType: [];
				default: [atomic];
			}, parseType(), []);
		return atomic;
	}

	/** A structure's `function name(a:A, ?b:B):R` field after its name, as the type `(A, ?B) -> R`. */
	function parseMethodFieldType():AstType {
		consume(TokenKind.LeftParen);
		var arguments = [], optionals:Array<Bool> = [];
		if (!check(TokenKind.RightParen))
			do {
				var optional = match(TokenKind.Question);
				consume(TokenKind.Identifier);
				consume(TokenKind.Colon);
				var argument = parseType();
				arguments.push(optional ? NullableType(argument) : argument);
				optionals.push(optional);
			} while (match(TokenKind.Comma));
		consume(TokenKind.RightParen);
		consume(TokenKind.Colon);
		return FunctionType(arguments, parseType(), optionals);
	}

	static function chainedFunctionType(arguments:Array<AstType>, result:AstType, optional:Array<Bool>):AstType
		return switch result {
			case FunctionType(nextArguments, finalResult, nextOptional):
				FunctionType(arguments.concat(nextArguments), finalResult,
					[for (index in 0...arguments.length) index < optional.length
					&& optional[index]].concat(nextOptional));
			default: FunctionType(arguments, result, optional);
		};

	function parseAtomicType():AstType {
		if (recovering && isExpressionTerminator(kindOf(current()))) {
			var span = new SourceSpan(spanOf(current()).file, startOf(current()), startOf(current()));
			recordRecoveryDiagnostic(new compiler.core.Diagnostic("E0002", "Expected type", span));
			return ErrorType(span);
		}
		if (match(TokenKind.LeftBrace)) {
			var fields = [];
			while (!check(TokenKind.RightBrace)) {
				var optional = false;
				var isFinal = false;
				var metadata = parseMetadata();
				for (entry in metadata)
					if (entry.name == "optional")
						optional = true;
				while (check(TokenKind.Question) || check(TokenKind.Final) || check(TokenKind.Var))
					if (match(TokenKind.Question)) {
						if (optional)
							fail(previous(), "Duplicate optional field marker");
						optional = true;
					} else if (match(TokenKind.Final))
						isFinal = true;
					else
						advance();
				// A `function` field is a method: read-only, like a final field of its function type.
				var method = match(TokenKind.Function);
				if (method)
					isFinal = true;
				var name = consume(TokenKind.Identifier);
				var type:AstType;
				if (method)
					type = parseMethodFieldType();
				else {
					// A property field `var x(default, null):T` is read like any field; one written only by its owner or never
					// is read-only. A structure has no accessor methods, so get, set and dynamic wait for class instances as
					// structures (docs/design/STRUCTURE_VALUES.md, step 4).
					if (match(TokenKind.LeftParen)) {
						var read = parseFieldAccess();
						consume(TokenKind.Comma);
						var write = parseFieldAccess();
						consume(TokenKind.RightParen);
						switch [read, write] {
							case [DefaultAccess, DefaultAccess]:
							case [DefaultAccess, NullAccess | NeverAccess]:
								isFinal = true;
							default:
								fail(name,
									'Structure field "${textOf(name)}" only supports (default, default), (default, null) and (default, never) access');
						}
					}
					consume(TokenKind.Colon);
					type = parseType();
				}
				fields.push({
					name: textOf(name),
					type: type,
					optional: optional,
					isFinal: isFinal,
					metadata: metadata,
					span: spanBetween(name, previous())
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
			if (textOf(current()) == "Array") {
				advance();
				consume(TokenKind.Less);
				var element = parseType();
				consume(TokenKind.Greater);
				return ArrayType(element);
			} else if (textOf(current()) == "Map") {
				advance();
				consume(TokenKind.Less);
				var key = parseType();
				consume(TokenKind.Comma);
				var value = parseType();
				consume(TokenKind.Greater);
				return MapType(key, value);
			} else if (textOf(current()) == "Null") {
				advance();
				consume(TokenKind.Less);
				var element = parseType();
				consume(TokenKind.Greater);
				return NullableType(element);
			}
		var name = parseQualifiedName();
		if (check(TokenKind.Less) && peekKind(1) == TokenKind.StringLiteral) {
			advance();
			var tag = consume(TokenKind.StringLiteral),
				value = decodeString(textOf(tag), spanOf(tag));
			consume(TokenKind.Greater);
			return NativeAbstractType(name, value);
		}
		if (match(TokenKind.Less)) {
			var arguments = [];
			do arguments.push(parseType()) while (match(TokenKind.Comma));
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
			if (check(TokenKind.Defer))
				fail(current(), "A defer statement requires an enclosing block");
			if (check(TokenKind.Identifier) && textOf(current()) == "scoped" && peekKind(1) == TokenKind.Var)
				fail(current(), "A scoped binding requires an enclosing block");
			var statements = [];
			parseStatements(statements);
			return statements;
		}
		var statements = [];
		while (!check(TokenKind.RightBrace) && !check(TokenKind.Eof))
			parseStatements(statements);
		consume(TokenKind.RightBrace);
		return statements;
	}

	function statementEnd(statements:Array<AstStatement>):SourceSpan
		return statements.length == 0 ? spanOf(previous()) : statementSpan(statements[statements.length - 1]);

	inline function match(kind:TokenKind):Bool {
		if (tokens.kind(current()) != kind)
			return false;
		position++;
		return true;
	}

	function consume(kind:TokenKind):TokenId {
		var token = current();
		if (tokens.kind(token) == kind) {
			position++;
			return token;
		}
		if (recovering && canInsert(kind))
			return insertMissing(kind);
		fail(token, 'Expected $kind, got ${tokens.kind(token)}');
		return token;
	}

	function recoveringAtEnd():Bool
		return recovering && check(TokenKind.Eof);

	function canInsert(kind:TokenKind):Bool
		return switch kind {
			case TokenKind.Semicolon: check(TokenKind.RightBrace) || check(TokenKind.Eof) || isTopLevelStart(current());
			case TokenKind.RightParen:
				check(TokenKind.LeftBrace)
					|| check(TokenKind.Colon)
					|| check(TokenKind.Semicolon)
					|| check(TokenKind.Arrow)
					|| check(TokenKind.Eof);
			case TokenKind.RightBracket:
				check(TokenKind.Assign)
					|| check(TokenKind.Semicolon)
					|| check(TokenKind.Comma)
					|| check(TokenKind.RightParen)
					|| check(TokenKind.Eof);
			case TokenKind.Colon, TokenKind.LeftBrace:
				check(TokenKind.Eof);
			case TokenKind.RightBrace:
				check(TokenKind.Eof);
			default: false;
		};

	/** A token recovery inserts, which the cursor never reaches: an id past the source's tokens. */
	function insertMissing(kind:TokenKind):TokenId {
		var replacement = tokenText(kind),
			span = new SourceSpan(spanOf(current()).file, startOf(current()), startOf(current()));
		recordRecoveryDiagnostic(new compiler.core.Diagnostic("E0002",
			'Expected $kind, got ${kindOf(current())}', span,
			compiler.core.Diagnostic.DiagnosticSeverity.Error,
			[
				{
					id: "insert-" + replacement,
					title: 'Insert "$replacement"',
					edits: [{span: span, replacement: replacement}]
				}
			]));
		inserted.push(new Token(kind, replacement, span));
		return TokenId.ofRow(tokenCount + inserted.length - 1);
	}

	function missingFunctionBody():Void {
		var span = new SourceSpan(spanOf(current()).file, startOf(current()), startOf(current()));
		recordRecoveryDiagnostic(new compiler.core.Diagnostic("E0002", "Expected function body", span,
			compiler.core.Diagnostic.DiagnosticSeverity.Error, [
				{id: "insert-function-body", title: "Insert function body", edits: [{span: span, replacement: " {}"}]}
			]));
	}

	function recordRecoveryDiagnostic(diagnostic:compiler.core.Diagnostic):Void {
		if (recoveryDiagnostics.length < MAX_RECOVERY_DIAGNOSTICS)
			recoveryDiagnostics.push(diagnostic);
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

	function consumeName():TokenId {
		if (!isNameToken(kindOf(current())))
			fail(current(), 'Expected name, got ${kindOf(current())}');
		return advance();
	}

	function expressionEnd(expression:AstExpression):SourceSpan {
		if (match(TokenKind.Semicolon))
			return spanOf(previous());
		// As in Haxe, an expression whose last token closes a brace needs no semicolon: `var x = try f() catch (e:Dynamic) { 0; }`; nor does
		// one whose last token ended a statement, as an arrow function with a loop body does: `var f = () -> for (x in xs) g(x);`.
		if (isBracedExpression(expression)
			|| kindOf(previous()) == TokenKind.RightBrace
			|| kindOf(previous()) == TokenKind.Semicolon
			|| (tryBodyDepth > 0 && check(TokenKind.Catch)))
			return expressionSpan(expression);
		// `if (c) a else b`: the `then` branch needs no semicolon before its `else`.
		if (check(TokenKind.Else))
			return expressionSpan(expression);
		return spanOf(consume(TokenKind.Semicolon));
	}

	static function isBracedExpression(expression:AstExpression):Bool
		return switch expression {
			case SwitchExpression(_, _, _, _), BlockExpression(_, _, _): true;
			case Conditional(_, whenTrue, whenFalse, _): isBracedExpression(whenTrue) || isBracedExpression(whenFalse);
			default: false;
		};

	static function isNameToken(kind:TokenKind):Bool {
		return switch kind {
			case TokenKind.Identifier, TokenKind.TypeInt, TokenKind.TypeBool, TokenKind.TypeFloat, TokenKind.TypeString,
				TokenKind.Void: true;
			default:
				false;
		};
	}

	inline function check(kind:TokenKind):Bool
		return tokens.kind(current()) == kind;

	function advance():TokenId
		return TokenId.ofRow(position++);

	inline function current():TokenId
		return TokenId.ofRow(position);

	/** The token `offset` tokens ahead of the cursor. */
	inline function ahead(offset:Int):TokenId
		return TokenId.ofRow(position + offset);

	function peekKind(offset:Int):TokenKind
		return position + offset < tokenCount ? tokens.kind(ahead(offset)) : TokenKind.Eof;

	inline function kindAt(row:Int):TokenKind
		return tokens.kind(TokenId.ofRow(row));

	function previous():TokenId
		return TokenId.ofRow(position - 1);

	function spanOf(token:TokenId):SourceSpan
		return token.row < tokenCount ? tokens.span(token) : inserted[token.row - tokenCount].span;

	function textOf(token:TokenId):String
		return token.row < tokenCount ? tokens.text(token) : inserted[token.row - tokenCount].text;

	function kindOf(token:TokenId):TokenKind
		return token.row < tokenCount ? tokens.kind(token) : inserted[token.row - tokenCount].kind;

	/** Where `token` starts and ends: offsets of a source token, without making its span. */
	function startOf(token:TokenId):Int
		return token.row < tokenCount ? tokens.start(token) : inserted[token.row - tokenCount].span.start;

	function endOf(token:TokenId):Int
		return token.row < tokenCount ? tokens.end(token) : inserted[token.row - tokenCount].span.end;

	/** The file of the tokens. */
	function fileOf(token:TokenId):SourceFile
		return token.row < tokenCount ? tokens.file : inserted[token.row - tokenCount].span.file;

	/** `spanOf(first).merge(spanOf(last))`, without making either token's span. */
	function spanBetween(first:TokenId, last:TokenId):SourceSpan {
		var start = startOf(first), end = endOf(last);
		return new SourceSpan(fileOf(first), start < startOf(last) ? start : startOf(last),
			end > endOf(first) ? end : endOf(first));
	}

	/** `start.merge(spanOf(last))`, without making the token's span. */
	function spanTo(start:SourceSpan, last:TokenId):SourceSpan {
		var from = startOf(last), to = endOf(last);
		return new SourceSpan(start.file, start.start < from ? start.start : from, start.end > to ? start.end : to);
	}

	/** `spanOf(first).merge(span)`, without making the token's span. */
	function spanFrom(first:TokenId, span:SourceSpan):SourceSpan {
		var from = startOf(first), to = endOf(first);
		return new SourceSpan(fileOf(first), from < span.start ? from : span.start, to > span.end ? to : span.end);
	}

	function fail(token:TokenId, message:String):Void
		throw new CompileError(new Diagnostic("E0002", message, spanOf(token)));

	function parseIntegerToken(token:TokenId, negative:Bool = false):Int {
		var hexadecimal = isHexIntegerToken(token),
			limit = hexadecimal ? Int64.parseString(negative ? "2147483648" : "4294967295")
				: Int64.parseString(negative ? "2147483648" : "2147483647"),
			magnitude = parseIntegerMagnitude(token);
		if (Int64.compare(magnitude, limit) > 0)
			fail(token,
				'Integer literal "${negative ? "-" : ""}${textOf(token)}" is outside the ${hexadecimal && !negative ? "unsigned" : "signed"} 32-bit range');
		var signed = negative ? Int64.sub(Int64.ofInt(0), magnitude) : magnitude;
		if (hexadecimal && !negative && Int64.compare(signed, Int64.parseString("2147483647")) > 0)
			signed = Int64.sub(signed, Int64.parseString("4294967296"));
		return Int64.toInt(signed);
	}

	function isHexIntegerToken(token:TokenId):Bool
		return StringTools.startsWith(textOf(token), "0x") || StringTools.startsWith(textOf(token), "0X");

	function parseIntegerMagnitude(token:TokenId):Int64 {
		if (isHexIntegerToken(token)) {
			var value = Int64.ofInt(0);
			var normalized = normalizeNumericLiteral(textOf(token));
			for (index in 2...normalized.length) {
				if (Int64.compare(Int64.ushr(value, 60), Int64.ofInt(0)) != 0)
					fail(token, 'Integer literal "${textOf(token)}" is outside the supported range');
				var code = normalized.charCodeAt(index),
					digit = code >= "0".code
						&& code <= "9".code ? code - "0".code : code >= "A".code
						&& code <= "F".code ? code - "A".code + 10 : code - "a".code + 10;
				value = Int64.or(Int64.shl(value, 4), Int64.ofInt(digit));
			}
			if (Int64.compare(value, Int64.ofInt(0)) < 0)
				fail(token, 'Integer literal "${textOf(token)}" is outside the supported range');
			return value;
		}
		try {
			var value = Int64.parseString(normalizeNumericLiteral(textOf(token)));
			if (Int64.compare(value, Int64.ofInt(0)) < 0)
				fail(token, 'Integer literal "${textOf(token)}" is outside the supported range');
			return value;
		} catch (_:Dynamic) {
			throw new CompileError(new Diagnostic("E0002",
				'Integer literal "${textOf(token)}" is outside the supported range', spanOf(token)));
		}
	}

	static inline function normalizeNumericLiteral(value:String):String
		return StringTools.replace(value, "_", "");

	function parseKeyPathLiteral(start:SourceSpan):AstExpression {
		var name = parseQualifiedName(), root:AstType = NamedType(name), fields:Array<String> = [];
		if (match(TokenKind.Less)) {
			var arguments:Array<AstType> = [];
			do arguments.push(parseType()) while (match(TokenKind.Comma));
			consume(TokenKind.Greater);
			root = AppliedType(name, arguments);
			while (match(TokenKind.Dot))
				fields.push(textOf(consume(TokenKind.Identifier)));
		}
		return KeyPathLiteral(root, fields, spanTo(start, previous()));
	}

	public static function expressionSpan(expression:AstExpression):SourceSpan
		return switch expression {
			case AnnotatedExpression(_, _, span): span;
			case IntegerLiteral(_, span), FloatLiteral(_, span), StringLiteral(_, span), BoolLiteral(_, span),
				NullLiteral(span), Unreachable(span),
				EmptyExpression(span), ErrorExpression(span), Variable(_, span), TemporaryVariable(_, span),
				DeclaredVariable(_, _, span),
				Member(_, _, span),
				Add(_, _, span),
				Sub(_, _, span), Mul(_, _, span),
				Div(_, _, span), Mod(_, _, span), BitAnd(_, _, span), BitXor(_, _, span), BitOr(_, _, span),
				ShiftLeft(_, _, span), ShiftRight(_, _, span),
				UnsignedShiftRight(_, _, span), Negate(_, span), Less(_, _, span), LessEqual(_, _, span),
				Greater(_, _, span), GreaterEqual(_, _, span),
				Equal(_, _, span), NotEqual(_, _, span), Not(_, span), Call(_, _, span), ClosureCall(_, _, span),
				MethodCall(_, _, _, span), New(_, _, span),
				NewGeneric(_, _, _, span), NativeLayoutQuery(_, _, _, span), KeyPathLiteral(_, _, span),
				NewArray(_, _, span), NewMap(_, _, span), Index(_, _, span),
				PostfixIncrement(_, _, span), AssignmentValue(_, span), Lambda(_, _, _, span), And(_, _, span),
				Or(_, _, span), Conditional(_, _, _, span), BlockExpression(_, _, span),
				ThrowExpression(_, span), SwitchExpression(_, _, _, span), Cast(_, _, span), CheckType(_, _, span),
				Capture(_, _, span), Extractor(_, _, span), Spread(_, span): span;
			case ObjectLiteral(_, span), ArrayLiteral(_, span), MapLiteral(_, span),
				ArrayComprehension(_, _, _, _, _, _, span),
				MapComprehension(_, _, _, _, _, _, span), Range(_, _, span): span;
		}

	/** The text of a quoted literal, with escapes decoded. Runs between escapes are copied whole: appending one character at a time made a long literal quadratic. */
	static function decodeString(text:String, span:SourceSpan):String {
		var end = text.length - 1, escapeAt = text.indexOf("\\", 1);
		if (escapeAt < 0 || escapeAt >= end)
			return text.substring(1, end);
		var out = new StringBuf(), start = 1;
		while (escapeAt >= 0 && escapeAt < end) {
			out.addSub(text, start, escapeAt - start);
			var escape = readEscape(text, escapeAt + 1, end, span);
			out.add(escape.value);
			start = escape.next;
			escapeAt = text.indexOf("\\", start);
		}
		out.addSub(text, start, end - start);
		return out.toString();
	}

	/**
	 * Decodes the escape whose character after the backslash is at `index`; `end` bounds the literal's content.
	 * Besides the single-character escapes it reads `\xHH`, `\uHHHH`, `\u{H...}` and three-digit octal `\NNN`
	 * (first digit 0-3) as Unicode code points, and joins a `\uD83D\uDE00` surrogate pair into one character.
	 * Any other escaped character stands for itself.
	 */
	static function readEscape(text:String, index:Int, end:Int, span:SourceSpan):{value:String, next:Int} {
		if (index >= end)
			return {value: "\\", next: index};
		var escaped = text.charAt(index);
		switch escaped {
			case "n":
				return {value: "\n", next: index + 1};
			case "r":
				return {value: "\r", next: index + 1};
			case "t":
				return {value: "\t", next: index + 1};
			case "x":
				var code = hexDigits(text, index + 1, 2, end);
				if (code < 0)
					invalidEscape("\\x needs two hexadecimal digits", span);
				return {value: codePointString(code, span), next: index + 3};
			case "u":
				if (index + 1 < end && text.charAt(index + 1) == "{") {
					var close = text.indexOf("}", index + 2);
					if (close < 0 || close >= end || close == index + 2 || close - index - 2 > 6)
						invalidEscape("\\u{...} needs one to six hexadecimal digits", span);
					var braced = hexDigits(text, index + 2, close - index - 2, end);
					if (braced < 0)
						invalidEscape("\\u{...} needs one to six hexadecimal digits", span);
					return {value: codePointString(braced, span), next: close + 1};
				}
				var unit = hexDigits(text, index + 1, 4, end);
				if (unit < 0)
					invalidEscape("\\u needs four hexadecimal digits", span);
				if (unit >= 0xD800 && unit <= 0xDBFF && index + 6 < end && text.charAt(index + 5) == "\\"
					&& text.charAt(index + 6) == "u") {
					var low = hexDigits(text, index + 7, 4, end);
					if (low >= 0xDC00 && low <= 0xDFFF)
						return {
							value: codePointString(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00), span),
							next: index + 11
						};
				}
				return {value: codePointString(unit, span), next: index + 5};
			case "0", "1", "2", "3":
				var octal = 0, digits = 0;
				while (digits < 3 && index + digits < end) {
					var digit = text.charCodeAt(index + digits) - "0".code;
					if (digit < 0 || digit > 7)
						break;
					octal = octal * 8 + digit;
					digits++;
				}
				if (digits != 3)
					invalidEscape("an octal escape needs three digits", span);
				return {value: codePointString(octal, span), next: index + 3};
			default:
				return {value: escaped, next: index + 1};
		}
	}

	/** The value of exactly `count` hexadecimal digits at `start`, or -1 when they are not all there. */
	static function hexDigits(text:String, start:Int, count:Int, end:Int):Int {
		if (count <= 0 || start + count > end)
			return -1;
		var value = 0;
		for (offset in 0...count) {
			var code = text.charCodeAt(start + offset), digit = -1;
			if (code >= "0".code && code <= "9".code)
				digit = code - "0".code;
			else if (code >= "a".code && code <= "f".code)
				digit = code - "a".code + 10;
			else if (code >= "A".code && code <= "F".code)
				digit = code - "A".code + 10;
			if (digit < 0)
				return -1;
			value = value * 16 + digit;
		}
		return value;
	}

	/** One Unicode code point as a string, encoded as UTF-8 so it reads the same on every host. */
	static function codePointString(code:Int, span:SourceSpan):String {
		if (code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF))
			invalidEscape("U+" + StringTools.hex(code, 4) + " is not a Unicode scalar value", span);
		// HashLink strings are NUL-terminated and cannot hold one; fail here, at the literal, not when the module is written.
		if (code == 0)
			invalidEscape("a String cannot contain NUL (U+0000); use Bytes for binary data", span);
		var bytes = new haxe.io.BytesOutput();
		if (code < 0x80)
			bytes.writeByte(code);
		else if (code < 0x800) {
			bytes.writeByte(0xC0 | (code >> 6));
			bytes.writeByte(0x80 | (code & 0x3F));
		} else if (code < 0x10000) {
			bytes.writeByte(0xE0 | (code >> 12));
			bytes.writeByte(0x80 | ((code >> 6) & 0x3F));
			bytes.writeByte(0x80 | (code & 0x3F));
		} else {
			bytes.writeByte(0xF0 | (code >> 18));
			bytes.writeByte(0x80 | ((code >> 12) & 0x3F));
			bytes.writeByte(0x80 | ((code >> 6) & 0x3F));
			bytes.writeByte(0x80 | (code & 0x3F));
		}
		return bytes.getBytes().toString();
	}

	@:noReturn
	static function invalidEscape(message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic("E0001", 'Invalid escape sequence: $message', span));

	function parseStringExpression(token:TokenId):AstExpression {
		var text = textOf(token);
		if (text.charAt(0) != "'" || text.indexOf("$") < 0)
			return StringLiteral(decodeString(text, spanOf(token)), spanOf(token));
		var parts:Array<AstExpression> = [], literal = new StringBuf(), index = 1, end = text.length - 1;
		while (index < end) {
			var character = text.charAt(index);
			if (character == "\\") {
				var escape = readEscape(text, index + 1, end, spanOf(token));
				literal.add(escape.value);
				index = escape.next;
				continue;
			}
			if (character != "$") {
				var next = index + 1;
				while (next < end && text.charCodeAt(next) != "\\".code && text.charCodeAt(next) != "$".code)
					next++;
				literal.addSub(text, index, next - index);
				index = next;
				continue;
			}
			if (index + 1 < end && text.charAt(index + 1) == "$") {
				literal.add("$");
				index += 2;
				continue;
			}
			if (index + 1 >= end || text.charAt(index + 1) != "{"
				&& !isInterpolationIdentifierStart(text.charCodeAt(index + 1))) {
				literal.add("$");
				index++;
				continue;
			}
			appendStringLiteral(parts, literal.toString(), spanOf(token));
			literal = new StringBuf();
			var expressionStart = index + 1, expressionEnd = expressionStart;
			if (expressionStart < end && text.charAt(expressionStart) == "{") {
				expressionStart++;
				expressionEnd = interpolationEnd(text, expressionStart, end, spanOf(token));
				index = expressionEnd + 1;
			} else {
				while (expressionEnd < end && isInterpolationIdentifierPart(text.charCodeAt(expressionEnd)))
					expressionEnd++;
				index = expressionEnd;
			}
			var expression = parseInterpolatedExpression(text.substring(expressionStart, expressionEnd), spanOf(token),
				haxe.io.Bytes.ofString(text.substring(0, expressionStart)).length);
			parts.push(Call("Std.string", [expression], expressionSpan(expression)));
		}
		appendStringLiteral(parts, literal.toString(), spanOf(token));
		var result = parts[0];
		for (partIndex in 1...parts.length)
			result = Add(result, parts[partIndex], expressionSpan(result).merge(expressionSpan(parts[partIndex])));
		return result;
	}

	static function appendStringLiteral(parts:Array<AstExpression>, value:String, span:SourceSpan):Void {
		if (value.length > 0 || parts.length == 0)
			parts.push(StringLiteral(value, span));
	}

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

	function parseInterpolatedExpression(source:String, outer:SourceSpan, offset:Int):AstExpression {
		// The expression's tokens, at their places in the outer file.
		var interpolationFile = new compiler.core.Source.SourceFile(outer.file.path, source),
			lexed = new Lexer(interpolationFile).tokenizeTable();
		var parser = new Parser(lexed.moved(outer.file, outer.start + offset));
		parser.lambdaMember = lambdaMember;
		parser.lambdaCounts = lambdaCounts;
		parser.lambdaUndo = lambdaUndo;
		parser.lambdaPath = lambdaPath.copy();
		var expression = parser.parseExpression();
		parser.consume(TokenKind.Eof);
		lambdaCounts = parser.lambdaCounts;
		return expression;
	}

	static function isInterpolationIdentifierPart(code:Int):Bool
		return isInterpolationIdentifierStart(code) || code >= 48 && code <= 57;

	static function isInterpolationIdentifierStart(code:Int):Bool
		return code >= 65 && code <= 90 || code >= 97 && code <= 122 || code == 95;

	static function statementSpan(statement:AstStatement):SourceSpan
		return switch statement {
			case ErrorStatement(span), AnnotatedStatement(_, _, span): span;
			case UninitializedDeclaration(_, _, span), VarDeclaration(_, _, _, span), ScopedDeclaration(_, _, _, span),
				Assignment(_, _, span), TemporaryDeclaration(_, _, _, span), TemporaryAssignment(_, _, span),
				DeclaredAssignment(_, _, _, span),
				IndexAssignment(_, _, _, span), FieldAssignment(_, _, _, span), Return(_, span), ReturnVoid(span),
				Throw(_, span), Defer(_, span),
				Try(_, _, span), If(_, _, _, span), While(_, _, span),
				DoWhile(_, _,
				span), ForIn(_, _, _, _, span), Break(span), Continue(span), Switch(_, _, _, _, span),
				Increment(_, _, span), Expression(_, span): span;
		}
}
