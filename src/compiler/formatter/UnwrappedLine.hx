package compiler.formatter;

import compiler.syntax.Token.TokenKind;
import compiler.formatter.SyntaxAnnotator.SyntaxInfo;
import compiler.formatter.FormatToken.FormatTokenKind;
import compiler.formatter.FormatToken.FormatTokenTools;
import compiler.formatter.CommentAttachment.CommentAttachments;
import compiler.formatter.CommentAttachment.CommentAttachmentKind;

typedef UnwrappedLine = {
	final tokens:Array<FormatToken>;
	final indent:Int;
	final blankBefore:Int;
	final sourceStart:Int;
	final sourceEnd:Int;
}

/** Builds logical lines from statement/block boundaries before line layout. */
class UnwrappedLineBuilder {
	public static function build(tokens:Array<FormatToken>, syntax:SyntaxInfo, ?comments:CommentAttachments):Array<UnwrappedLine> {
		var result:Array<UnwrappedLine> = [], current:Array<FormatToken> = [], depth = 0, blankBefore = 0, pendingNewlines = 0,
			conditionalBases:Array<Int> = [], switchBases:Array<Int> = [], opaqueBlockDepth = 0, lastClosedBlock = false;

		function begin(token:FormatToken):Void {
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
				sourceEnd: current[current.length - 1].end
			});
			current = [];
			blankBefore = 0;
		}

		for (index in 0...tokens.length) {
			var token = tokens[index];
			switch token.kind {
				case FormatTokenKind.Whitespace:
					// Whitespace is represented by boundary policy, not copied to output.
				case FormatTokenKind.Newline:
					pendingNewlines++;
				case FormatTokenKind.Directive:
					var name = FormatScanner.directiveName(token.text);
					if (name == "else" || name == "elseif" || name == "end")
						if (conditionalBases.length > 0)
							depth = conditionalBases[conditionalBases.length - 1];
					flush();
					begin(token);
					flush();
					if (name == "if")
						conditionalBases.push(depth);
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
					begin(token);
					if (token.kind == FormatTokenKind.LineComment || current.length == 1)
						flush();
				case FormatTokenKind.Syntax(kind):
					var isBlock = kind == TokenKind.LeftBrace
						&& syntax.blockOpens.exists(token.start)
						&& syntax.blockOpens.get(token.start),
						isCloseBlock = kind == TokenKind.RightBrace && (syntax.blockCloses.exists(token.start) || opaqueBlockDepth > 0),
						isSwitchBlock = isBlock && containsKind(current, TokenKind.Switch),
						closesSwitch = isCloseBlock
							&& switchBases.length > 0
							&& (depth == switchBases[switchBases.length - 1] + 1 || depth == switchBases[switchBases.length - 1] + 2);
					if (current.length > 0 && endsDeclaration(current[current.length - 1], syntax))
						flush();
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
						&& kind != TokenKind.While
						&& kind != TokenKind.Semicolon
						&& kind != TokenKind.Comma
						&& kind != TokenKind.Dot
						&& kind != TokenKind.Greater)
						flush();
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
					if (isBlock) {
						flush();
						if (isSwitchBlock)
							switchBases.push(depth);
						depth++;
					} else if (kind == TokenKind.Semicolon) {
						// Defer flushing until the following token so a same-line
						// trailing comment remains attached to the statement.
					} else if (kind == TokenKind.Colon && switchBases.length > 0 && isCaseHeader(current)) {
						flush();
						depth = switchBases[switchBases.length - 1] + 2;
					}
					if (closesSwitch && switchBases.length > 0)
						switchBases.pop();
					lastClosedBlock = isCloseBlock;
			}
		}
		flush();
		return result;
	}

	/** A semicolon ends a statement, and a comma ends a field of a declaration list such as a typedef body. */
	static function endsDeclaration(token:FormatToken, syntax:SyntaxInfo):Bool
		return switch FormatTokenTools.syntaxKind(token) {
			case TokenKind.Semicolon: true;
			case TokenKind.Comma: syntax.declarationCommas.exists(token.start);
			default: false;
		};

	static function startsDeclaration(kind:TokenKind):Bool
		return switch kind {
			case TokenKind.Class, TokenKind.Typedef, TokenKind.Enum, TokenKind.Interface, TokenKind.Struct, TokenKind.Public, TokenKind.Private,
				TokenKind.Static, TokenKind.Function, TokenKind.Var, TokenKind.Final, TokenKind.Inline, TokenKind.Import, TokenKind.Package, TokenKind.At:
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
