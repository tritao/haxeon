package compiler.formatter;

import compiler.formatter.CommentAttachment.CommentAttachmentKind;
import compiler.formatter.CommentAttachment.CommentAttachments;
import compiler.formatter.FormatToken.FormatTokenKind;
import compiler.formatter.FormatToken.FormatTokenTools;
import compiler.formatter.SyntaxAnnotator.SyntaxInfo;
import compiler.syntax.Token.TokenKind;

typedef UnwrappedLine = {
	final tokens:Array<FormatToken>;
	final indent:Int;
	final blankBefore:Int;
	final sourceStart:Int;
	final sourceEnd:Int;

	/** Start offsets of the comments that trail code on their source line; layout keeps each on that line. */
	final ?trailingComments:Map<Int, Bool>;

	/**
	 * Start offsets of the tokens that began a source line inside this logical line. Layout keeps two of the author's choices from
	 * them: a literal written one element per line, and a declaration written one declarator per line.
	 */
	final ?newlineBefore:Map<Int, Bool>;
}

class UnwrappedLineTools {
	/**
	 * Whether `token` is a comment trailing code on its source line. Layout keeps it there whatever any rule wants (BreakAnalyzer)
	 * and never measures it (BreakAnalyzer's widths, LayoutSolver): it cannot be wrapped, so counting it would only push breaks into
	 * the code before it.
	 */
	public static function isTrailingComment(line:UnwrappedLine, token:FormatToken):Bool
		return line.trailingComments != null && line.trailingComments.exists(token.start);

	/** Whether `token` began a source line inside its logical line. */
	public static function beganSourceLine(line:UnwrappedLine, token:FormatToken):Bool
		return line.newlineBefore != null && line.newlineBefore.exists(token.start);
}

/** Builds logical lines from statement/block boundaries before line layout. */
class UnwrappedLineBuilder {
	public static function build(tokens:Array<FormatToken>, syntax:SyntaxInfo,
			?comments:CommentAttachments):Array<UnwrappedLine> {
		var result:Array<UnwrappedLine> = [],
			current:Array<FormatToken> = [],
			depth = 0,
			blankBefore = 0,
			pendingNewlines = 0,
			conditionalBases:Array<{depth:Int, nesting:Int, bodyLevels:Array<Int>}> = [],
			switchBases:Array<Int> = [],
		// The token index of each open switch's closing brace, from the bracket matching: a `}` closes the switch only if it is
		// that one, not whenever the depth looks like it (a case arm's own block closes at the same depth).
		switchCloses:Array<Int> = [], opaqueBlockDepth = 0, lastClosedBlock = false,
			trailingComments = new Map<Int, Bool>(),
		// A control statement's single-statement body (`if (c)` then `x;` on the next line) is indented one level until the
		// statement ends; each open body records the bracket nesting it started at.
		nesting = 0, bodyLevels:Array<Int> = [], pendingDedent = 0, previousSyntax = -1,
		// The `}` of an empty block (`{}`), which stays on the line of its `{`.
		emptyBlockCloses = new Map<Int, Bool>(),
			newlineBefore = new Map<Int, Bool>(),
		// The indentation of the lines after an inline case arm (`case 0: x;`), taken when that arm's line ends.
		pendingDepth:Null<Int> = null,
		// After the `)` of a function declaration's parameters: whether its return type is being read, and how deep in it.
		awaitingFunctionBody = false, inReturnType = false, returnTypeDepth = 0, returnTypeName = false;

		function begin(token:FormatToken):Void {
			if (current.length > 0 && pendingNewlines > 0)
				newlineBefore.set(token.start, true);
			if (current.length == 0) {
				blankBefore = pendingNewlines > 1 ? pendingNewlines - 1 : 0;
				pendingNewlines = 0;
			} else
			// Newlines inside an unwrapped construct are not blank lines
			// once another token continues that construct.
			pendingNewlines = 0;
			current.push(token);
		}

		function flush():Void {
			if (current.length == 0)
				return;
			result.push({
				tokens: current,
				indent: depth,
				blankBefore: blankBefore,
				sourceStart: current[0].start,
				sourceEnd: current[current.length - 1].end,
				trailingComments: trailingComments,
				newlineBefore: newlineBefore
			});
			current = [];
			blankBefore = 0;
			depth -= pendingDedent;
			pendingDedent = 0;
			if (pendingDepth != null) {
				depth = pendingDepth;
				pendingDepth = null;
			}
		}

		/** Ends every single-statement body opened at the current nesting: the statement they indent is complete. */
		function endBodies():Void {
			while (bodyLevels.length > 0 && bodyLevels[bodyLevels.length - 1] == nesting) {
				bodyLevels.pop();
				pendingDedent++;
			}
		}

		for (index in 0...tokens.length) {
			var token = tokens[index];
			switch token.kind {
				case FormatTokenKind.Whitespace:
				// Whitespace is represented by boundary policy, not copied to output.
				case FormatTokenKind.Newline:
					pendingNewlines++;
				case FormatTokenKind.Directive if (current.length > 0 && pendingNewlines == 0):
					// A directive written inside a line (`x = #if eval a #else b #end;`, `Array<#if hl Int #else Float #end>`) stays in
					// it: its branches are expressions or types of that line, not lines of their own.
					begin(token);
				case FormatTokenKind.Directive:
					var name = FormatScanner.directiveName(token.text);
					// The line before the directive ends in its own branch first, at its own depth and with its pending dedent.
					flush();
					if ((name == "else" || name == "elseif" || name == "end") && conditionalBases.length > 0) {
						// Each branch starts where the `#if` stood: its depth, bracket nesting and open single-statement bodies.
						var base = conditionalBases[conditionalBases.length - 1];
						depth = base.depth;
						if (name != "end") {
							nesting = base.nesting;
							bodyLevels = base.bodyLevels.copy();
						}
					}
					begin(token);
					flush();
					if (name == "if")
						conditionalBases.push({depth: depth, nesting: nesting, bodyLevels: bodyLevels.copy()});
					else if (name == "end" && conditionalBases.length > 0)
						conditionalBases.pop();
				case FormatTokenKind.FormatterOff:
					flush();
					begin(token);
					flush();
					var protectedDelta = braceDelta(token.text);
					depth = Std.int(Math.max(0, depth + protectedDelta));
					if (protectedDelta > 0)
						opaqueBlockDepth += protectedDelta;
				case FormatTokenKind.LineComment, FormatTokenKind.DocComment, FormatTokenKind.BlockComment:
					var attachment = comments == null || !comments.exists(index) ? null : comments.get(index);
					switch attachment {
						case CommentAttachmentKind.Leading(_), CommentAttachmentKind.Standalone:
							if (current.length > 0) flush();
						default:
					}
					if (pendingNewlines > 0
						&& current.length > 0
						&& endsDeclaration(current[current.length - 1], syntax))
						flush();
					var trailing = switch attachment {
						case CommentAttachmentKind.Trailing(_): true;
						default: false;
					};
					// A comment leading a `case` or `default` sits at the case's indent, not in the arm before it.
					switch attachment {
						case CommentAttachmentKind.Leading(next) if (switchBases.length > 0 && current.length == 0):
							switch FormatTokenTools.syntaxKind(tokens[next]) {
								case TokenKind.Case, TokenKind.Default:
									flush();
									pendingDepth = null;
									depth = switchBases[switchBases.length - 1] + 1;
								default:
							}
						default:
					}
					if (trailing)
						trailingComments.set(token.start, true);
					begin(token);
					// A line comment ends the logical line, unless it trails a statement that goes on below it (`var a = 1, // why`
					// then `b = 2;`, or an argument list): the rest keeps the statement's continuation indent.
					if (current.length == 1 || token.kind.match(FormatTokenKind.LineComment)
						&& !(trailing && statementContinues(current, syntax)))
						flush();
				case FormatTokenKind.Syntax(kind):
					var isBlock = kind == TokenKind.LeftBrace
						&& syntax.blockOpens.exists(token.start)
						&& syntax.blockOpens.get(token.start),
						isEmptyClose = emptyBlockCloses.exists(index),
						isCloseBlock = !isEmptyClose
							&& kind == TokenKind.RightBrace
							&& (syntax.blockCloses.exists(token.start) || opaqueBlockDepth > 0),
						isSwitchBlock = isBlock && containsKind(current,
							TokenKind.Switch),
						closesSwitch = isCloseBlock
							&& switchCloses.length > 0
							&& index == switchCloses[switchCloses.length - 1];
					if (current.length > 0 && endsDeclaration(current[current.length - 1], syntax))
						flush();
					// A declaration's expression body (`function f():Int` then `return 1;`) starts its own line, like a control body.
					var functionBody = false;
					if (awaitingFunctionBody) {
						// A name right after a name ends the type: `):Void AudioResult.check(...)` is a body after `Void`.
						var name = TypeArguments.isTypeName(kind);
						if (inReturnType && !(name && returnTypeName && returnTypeDepth == 0)
							&& continuesReturnType(tokens, index, returnTypeDepth, syntax)) {
							returnTypeDepth += returnTypeNesting(tokens, index, syntax);
							returnTypeName = name;
						} else if (!inReturnType && kind == TokenKind.Colon) {
							inReturnType = true;
							returnTypeDepth = 0;
							returnTypeName = false;
						} else {
							awaitingFunctionBody = false;
							functionBody = kind != TokenKind.LeftBrace && kind != TokenKind.Semicolon;
						}
					}
					// A single-statement body stays where its author put it: on the header's line, or on its own line below.
					if (previousSyntax >= 0
						&& brokenBefore(tokens, previousSyntax, index)
						&& (functionBody
						|| kind != TokenKind.LeftBrace && kind != TokenKind.Semicolon && current.length > 0
						&& opensSingleBody(tokens, previousSyntax, current, syntax, kind))) {
						flush();
						depth++;
						bodyLevels.push(nesting);
					}
					if (kind == TokenKind.Case || kind == TokenKind.Default) {
						if (switchBases.length > 0) {
							flush();
							depth = switchBases[switchBases.length - 1] + 1;
						}
						begin(token);
						continue;
					}
					// A block's closing brace ends the statement. The `}` of an object literal or a structure type continues it,
					// unless a declaration follows: `typedef T = {...}` needs no semicolon.
					if (current.length > 0
						&& FormatTokenTools.syntaxKind(current[current.length - 1]) == TokenKind.RightBrace
						&& (lastClosedBlock || startsDeclaration(kind))
						&& kind != TokenKind.Else
						&& kind != TokenKind.Catch
						&& !(kind == TokenKind.While
						&& syntax.roles.doBlockCloses.exists(current[current.length - 1].start))
						&& kind != TokenKind.Semicolon
					// A bracket that closes after a block (`call(function() {...})`) closes the expression around it, and an operator
					// or a conditional's `?` or `:` after one (`f == null ? function() {} : f`) continues it.
					&& kind != TokenKind.RightParen
						&& kind != TokenKind.RightBracket
						&& kind != TokenKind.Question
						&& !(kind == TokenKind.Colon && syntax.roles.ternaryColons.exists(token.start))
						&& !TokenRoles.isBinaryOperator(kind)
						&& kind != TokenKind.Comma
						&& kind != TokenKind.Dot
						&& kind != TokenKind.Greater) flush();
					if (isCloseBlock) {
						flush();
						if (closesSwitch)
							depth = switchBases[switchBases.length - 1] + 1;
						depth = depth > 0 ? depth - 1 : 0;
						if (opaqueBlockDepth > 0)
							opaqueBlockDepth--;
						begin(token);
					} else {
						begin(token);
					}
					var emptyClose = isBlock && closesNext(tokens, index, syntax) ? syntax.matching.get(index) : null;
					if (emptyClose != null) {
						// `{}`: an empty block stays whole on its line; its `}` still ends the block's statement below.
						emptyBlockCloses.set(emptyClose, true);
					} else if (isBlock) {
						flush();
						if (isSwitchBlock)
							{
							switchBases.push(depth);
							switchCloses.push(syntax.matching.exists(index) ? syntax.matching.get(index) : -1);
						}
						depth++;
					} else if (kind == TokenKind.Semicolon) {
						// Defer flushing until the following token so a same-line
						// trailing comment remains attached to the statement.
					} else if (kind == TokenKind.Colon && switchBases.length > 0 && isCaseHeader(current)) {
						// An arm its author wrote on the case's line (`case 0: x;`, `case A: {`) stays there; otherwise its body starts
						// the next line. Either way the lines after it are the arm's body.
						var body = FormatTokenTools.nextSyntax(tokens, index);
						if (body < 0 || brokenBefore(tokens, index, body)) {
							flush();
							depth = switchBases[switchBases.length - 1] + 2;
						} else if (FormatTokenTools.syntaxKind(tokens[body]) != TokenKind.LeftBrace)
							pendingDepth = switchBases[switchBases.length - 1] + 2;
					}
					if (closesSwitch && switchBases.length > 0) {
						switchBases.pop();
						switchCloses.pop();
					}
					lastClosedBlock = isCloseBlock || isEmptyClose;
					switch kind {
						case TokenKind.LeftParen, TokenKind.LeftBracket, TokenKind.LeftBrace:
							nesting++;
						case TokenKind.RightParen, TokenKind.RightBracket, TokenKind.RightBrace:
							nesting = nesting > 0 ? nesting - 1 : 0;
							// A block that closes back at a body's level completes that body, unless its statement goes on (`else`).
							if (kind == TokenKind.RightBrace && !continuesAfterBlock(tokens, index, syntax))
								endBodies();
						case TokenKind.Semicolon:
							// `else` next continues the `if` whose body just ended; the bodies around that `if` go on.
							var next = FormatTokenTools.nextSyntax(tokens, index);
							if (next >= 0 && FormatTokenTools.syntaxKind(tokens[next]) == TokenKind.Else) {
								if (bodyLevels.length > 0 && bodyLevels[bodyLevels.length - 1] == nesting) {
									bodyLevels.pop();
									pendingDedent++;
								}
							} else
								endBodies();
						default:
					}
					previousSyntax = index;
					if (kind == TokenKind.RightParen && closesDeclarationParameters(tokens, index, current, syntax)) {
						awaitingFunctionBody = true;
						inReturnType = false;
					}
			}
		}
		flush();
		return result;
	}

	/** A semicolon ends a statement, and a comma ends a field of a declaration list such as a typedef body. */
	/** Whether the statement holding a trailing comment (the last token of `current`) is unfinished: its last code token ends nothing. */
	static function statementContinues(current:Array<FormatToken>, syntax:SyntaxInfo):Bool {
		var index = current.length - 2;
		while (index >= 0 && !FormatTokenTools.isSyntax(current[index]))
			index--;
		if (index < 0)
			return false;
		return switch FormatTokenTools.syntaxKind(current[index]) {
			case TokenKind.Semicolon, TokenKind.LeftBrace, TokenKind.RightBrace, TokenKind.Colon: false;
			case TokenKind.Comma: !syntax.declarationCommas.exists(current[index].start);
			default: true;
		};
	}

	/**
	 * Whether the code after `previous` is the single-statement body of a control statement that begins its line: `previous` is the
	 * `)` of `if (...)`, `for (...)` or `while (...)` or a bare `else`, at the start of `current` (after a `}` and `else`, for
	 * `} else if (...)`). An `if` inside an expression (`var x = if (a) 1 else 2;`) does not begin its line and stays as written.
	 */
	static function opensSingleBody(tokens:Array<FormatToken>, previous:Int, current:Array<FormatToken>,
			syntax:SyntaxInfo,
			next:TokenKind):Bool {
		var keyword:Null<FormatToken> = null;
		switch FormatTokenTools.syntaxKind(tokens[previous]) {
			case TokenKind.RightParen:
				var open = syntax.matching.get(previous);
				if (open == null)
					return false;
				var index = open - 1;
				while (index >= 0 && !FormatTokenTools.isSyntax(tokens[index]))
					index--;
				if (index < 0)
					return false;
				switch FormatTokenTools.syntaxKind(tokens[index]) {
					case TokenKind.If, TokenKind.For, TokenKind.While:
						keyword = tokens[index];
					default:
						return false;
				}
			case TokenKind.Else:
				// `else if` is one statement: the `if` is not a body of its own.
				if (next == TokenKind.If)
					return false;
				keyword = tokens[previous];
			default:
				return false;
		}
		for (token in current) {
			if (token == keyword)
				return true;
			if (!FormatTokenTools.isSyntax(token))
				continue;
			switch FormatTokenTools.syntaxKind(token) {
				case TokenKind.RightBrace, TokenKind.Else:
				default:
					return false;
			}
		}
		return false;
	}


	/** Whether a line break or a comment separates tokens `from` and `to`. */
	static function brokenBefore(tokens:Array<FormatToken>, from:Int, to:Int):Bool {
		for (index in from + 1...to)
			if (tokens[index].kind != FormatTokenKind.Whitespace)
				return true;
		return false;
	}

	/**
	 * Whether the `)` at `close` ends the parameters of a function declaration that begins its line (after metadata and modifiers):
	 * `function name(...)`, `function new(...)`, `function name<T>(...)`. A function expression (`var f = function() ...`) does not.
	 */
	static function closesDeclarationParameters(tokens:Array<FormatToken>, close:Int, current:Array<FormatToken>,
			syntax:SyntaxInfo):Bool {
		var open = syntax.matching.get(close);
		if (open == null)
			return false;
		var index = FormatTokenTools.previousSyntax(tokens, open);
		if (index >= 0 && syntax.typeArgumentCloses.exists(tokens[index].start)) {
			var typeOpen = syntax.matching.get(index);
			if (typeOpen == null)
				return false;
			index = FormatTokenTools.previousSyntax(tokens, typeOpen);
		}
		if (index < 0)
			return false;
		switch FormatTokenTools.syntaxKind(tokens[index]) {
			case TokenKind.Identifier, TokenKind.New:
				index = FormatTokenTools.previousSyntax(tokens, index);
			default:
				return false;
		}
		if (index < 0 || FormatTokenTools.syntaxKind(tokens[index]) != TokenKind.Function)
			return false;
		// Only metadata and modifiers may come before `function` on the line.
		var position = 0, metadataDepth = 0;
		while (position < current.length && current[position] != tokens[index]) {
			var token = current[position++];
			if (!FormatTokenTools.isSyntax(token))
				continue;
			var kind = FormatTokenTools.syntaxKind(token);
			if (metadataDepth > 0) {
				if (kind == TokenKind.LeftParen)
					metadataDepth++;
				else if (kind == TokenKind.RightParen)
					metadataDepth--;
				continue;
			}
			switch kind {
				case TokenKind.Public, TokenKind.Private, TokenKind.Static, TokenKind.Inline, TokenKind.At,
					TokenKind.Colon, TokenKind.Identifier:
				case TokenKind.LeftParen if (position >= 2):
					metadataDepth = 1;
				default:
					return false;
			}
		}
		return position < current.length;
	}

	/** Whether the token at `index` continues a return type whose open brackets are `depth` deep. */
	static function continuesReturnType(tokens:Array<FormatToken>, index:Int, depth:Int, syntax:SyntaxInfo):Bool {
		if (depth > 0)
			return true;
		if (syntax.typeArgumentOpens.exists(tokens[index].start))
			return true;
		return switch FormatTokenTools.syntaxKind(tokens[index]) {
			case TokenKind.Identifier, TokenKind.Dot, TokenKind.Arrow, TokenKind.Question, TokenKind.LeftParen,
				TokenKind.TypeInt, TokenKind.TypeBool,
				TokenKind.TypeFloat, TokenKind.TypeString, TokenKind.Void:
				true;
			default: false;
		};
	}



	/** How the token at `index` changes the bracket depth inside a return type. */
	static function returnTypeNesting(tokens:Array<FormatToken>, index:Int, syntax:SyntaxInfo):Int {
		if (syntax.typeArgumentOpens.exists(tokens[index].start))
			return 1;
		if (syntax.typeArgumentCloses.exists(tokens[index].start))
			return -1;
		return switch FormatTokenTools.syntaxKind(tokens[index]) {
			case TokenKind.LeftParen, TokenKind.LeftBrace: 1;
			case TokenKind.RightParen, TokenKind.RightBrace: -1;
			default: 0;
		};
	}

	/** Whether the token after `open` is its matching closer, with nothing between them but whitespace (a comment counts). */
	static function closesNext(tokens:Array<FormatToken>, open:Int, syntax:SyntaxInfo):Bool {
		var close = syntax.matching.get(open);
		if (close == null)
			return false;
		for (index in open + 1...close)
			switch tokens[index].kind {
				case FormatTokenKind.Whitespace, FormatTokenKind.Newline:
				default:
					return false;
			}
		return true;
	}

	/** Whether the statement a block belongs to goes on after its `}`: `} else`, `} catch`, or the `while` of a `do {...}` loop. */
	static function continuesAfterBlock(tokens:Array<FormatToken>, close:Int, syntax:SyntaxInfo):Bool {
		var index = close + 1;
		while (index < tokens.length && !FormatTokenTools.isSyntax(tokens[index]))
			index++;
		if (index >= tokens.length)
			return false;
		return switch FormatTokenTools.syntaxKind(tokens[index]) {
			case TokenKind.Else, TokenKind.Catch: true;
			case TokenKind.While: syntax.roles.doBlockCloses.exists(tokens[close].start);
			default: false;
		};
	}



	static function endsDeclaration(token:FormatToken, syntax:SyntaxInfo):Bool
		return switch FormatTokenTools.syntaxKind(token) {
			case TokenKind.Semicolon: true;
			case TokenKind.Comma: syntax.declarationCommas.exists(token.start);
			default: false;
		};

	static function startsDeclaration(kind:TokenKind):Bool
		return switch kind {
			case TokenKind.Class, TokenKind.Typedef, TokenKind.Enum, TokenKind.Interface, TokenKind.Struct,
				TokenKind.Public, TokenKind.Private,
				TokenKind.Static, TokenKind.Function, TokenKind.Var, TokenKind.Final, TokenKind.Inline,
				TokenKind.Import, TokenKind.Package, TokenKind.At:
				true;
			default: false;
		};

	static function containsKind(tokens:Array<FormatToken>, wanted:TokenKind):Bool {
		for (token in tokens)
			if (FormatTokenTools.syntaxKind(token) == wanted)
				return true;
		return false;
	}

	static function isCaseHeader(tokens:Array<FormatToken>):Bool {
		for (token in tokens)
			switch FormatTokenTools.syntaxKind(token) {
				case TokenKind.Case, TokenKind.Default:
					return true;
				default:
			}
		return false;
	}

	static function braceDelta(text:String):Int {
		var delta = 0, quote = 0, escaped = false, lineComment = false, blockComment = false, index = 0;
		while (index < text.length) {
			var code = text.charCodeAt(index),
				next = index + 1 < text.length ? text.charCodeAt(index + 1) : -1;
			if (lineComment) {
				if (code == 10 || code == 13)
					lineComment = false;
				index++;
				continue;
			}
			if (blockComment) {
				if (code == 42 && next == 47) {
					blockComment = false;
					index += 2;
				} else
					index++;
				continue;
			}
			if (quote != 0) {
				if (escaped)
					escaped = false;
				else if (code == 92)
					escaped = true;
				else if (code == quote)
					quote = 0;
				index++;
				continue;
			}
			if (code == 47 && next == 47) {
				lineComment = true;
				index += 2;
				continue;
			}
			if (code == 47 && next == 42) {
				blockComment = true;
				index += 2;
				continue;
			}
			if (code == 34 || code == 39)
				quote = code;
			else if (code == 123)
				delta++;
			else if (code == 125)
				delta--;
			index++;
		}
		return delta;
	}
}
